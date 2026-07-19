# Schema Evolution and Data Migrations

The playbook for changing data, not just schema: how to backfill or migrate data safely.

## Two risk classes, never blurred

Schema DDL and data migration fail differently. A bad `ALTER TABLE` fails loudly at deploy time,
and the artifact that caused it is one revert away. A bad `UPDATE` succeeds quietly, row by row;
by the time anyone notices, reverting the artifact no longer helps — the damage is in the data.
The pipeline therefore handles them differently ([ci-cd.md](ci-cd.md)): schema changes ride the
dacpac diff, gated by SqlPackage's data-loss block; data migrations are explicit, reviewed
scripts in `databases/<name>/Scripts/DataMigrations/` that run as their own step after the
publish. One rule follows: **no data migration hides inside a schema change.** A row rewrite is
a visible script with its own review, never a side effect.

## The playbook: expand → backfill → cut over → contract

Any change that reshapes populated data ships as **separate merges**, in order:

1. **Expand** — additive DDL only. The new column or table ships as a normal deploy, invisible
   to consumers that don't ask for it.
2. **Backfill** — an idempotent script in `Scripts/DataMigrations/` populates the new shape.
3. **Cut over** — consumers switch to the new shape on their own schedule, not mid-deploy.
4. **Contract** — destructive DDL. Dropping the old shape is a later, separately gated deploy,
   after a confidence period long enough that "nobody still reads the old column" is verified,
   not assumed.

Each phase is independently revertible. The most dangerous form of data migration is schema
change and data rewrite combined into a single deploy that can only be reverted as a unit —
the playbook exists to prevent that.

## Backfill discipline

**Batched, always.** Row rewrites run as bounded loops with pauses:

```sql
SET NOCOUNT ON;

-- SQLFluff CV06 wants a terminator on the WHILE; the loop is closed by END; below.
WHILE 1 = 1  -- noqa
    BEGIN
        UPDATE TOP (5000) [app].[Customer]
        SET [PreferredCurrency] = N'USD'
        WHERE [PreferredCurrency] IS NULL;

        IF @@ROWCOUNT = 0 BREAK;
        WAITFOR DELAY N'00:00:02';
    END;
```

(`WAITFOR` is banned in *schema* by the analyzer, but `Scripts/` are outside the compiled model,
so migration scripts may use it — [conventions.md](conventions.md).) These scripts **are** style-
linted by SQLFluff (unlike post-deployment scripts), so a migration follows the house style:
bracketed identifiers, `N'…'` literals, and the one `-- noqa` above, which suppresses SQLFluff's
spurious "missing terminator" on the batched `WHILE` loop (the loop is closed by `END;`).

Batching bounds lock duration and transaction size, and on this platform it matters twice:
compute is capacity-billed, so a monolithic update competes with user traffic for locks *and*
burns capacity units at full tilt — a runaway backfill is a billing and throttling event, not
just a blocking one. Declare batch size and pacing in the script header, and rehearse against
test at representative volume before prod runs it.

**Anchored.** Record a timestamp before the backfill starts — it is the point-in-time-restore
anchor if the backfill goes wrong ([ci-cd.md](ci-cd.md#recovery)).

**Verified.** Every migration ships with a verification query — row counts, checksums,
invariant assertions — that must return the expected result before the contract merge ships.
"The script finished" is not "the data is right"; running the query is a review and
operational check, not something the pipeline enforces.

**Idempotent.** Re-running after a partial failure must be safe: every write carries a
predicate excluding rows already processed. In the loop above, `WHERE PreferredCurrency IS
NULL` is the progress marker — the script resumes exactly where it stopped.

**Replication-aware.** A heavy backfill churns the OneLake replication that analytics reads.
Pause the database's replication around a large backfill and restart it after, so analytics
sees one clean transition ([operations.md](operations.md)).

## Worked example: making a column required on a populated table

Goal: `app.Customer` gets a mandatory `PreferredCurrency`. Done naively — a `NOT NULL` column
with a default in one deploy — every row is rewritten inside the publish, with the table locked
and nothing verified. On the playbook it is three small merges:

**Merge 1 — expand.** Edit `databases/AppDb/Tables/app.Customer.sql`:

```sql
[PreferredCurrency] CHAR(3) NULL
    CONSTRAINT [DF_Customer_PreferredCurrency] DEFAULT (N'USD')
```

Nullable, defaulted: new rows are correct from now on, existing rows untouched. The generated
migration is a metadata-only `ALTER TABLE ... ADD`, so it publishes cleanly.

**Merge 2 — backfill.** Add `Scripts/DataMigrations/backfill-customer-preferred-currency.sql` —
the batched loop above, with its header and its verification query:

```sql
-- Verification: must return 0 before contract may ship.
SELECT COUNT(*) AS remaining
FROM [app].[Customer]
WHERE [PreferredCurrency] IS NULL;
```

**Merge 3 — contract.** Edit the table file: `PreferredCurrency char(3) NOT NULL ...`. The
generated migration alters the column, which scans the table to validate — deploy it in a
low-traffic window. The verification query returning zero is the evidence this merge was safe
to open.

Three merges instead of one deploy: each small, reviewed as the exact T-SQL it runs, and
independently revertible.

## What the pipeline automates, and what it doesn't

Schema safety is SqlPackage's: a publish blocks a change that could lose data before touching
anything, and a reviewer overrides it deliberately for an intentional drop ([ci-cd.md](ci-cd.md)).
Data migrations the pipeline just runs: every `Scripts/DataMigrations/*.sql` executes after the
schema publish, in name order, on **every deploy that publishes** — there is no applied-history
table. (A leg whose sources already match the deployed hash skips the publish *and* the
migrations as provably-applied re-runs; and the completion stamp is written only after the
migrations finish, so a leg that dies mid-migration re-runs rather than being marked done —
[ci-cd.md](ci-cd.md).) So keep
scripts idempotent, and **prune a script once it has applied to every environment**: a finished
migration is dead weight, and one that reads a since-dropped column fails every subsequent
deploy. The batch header, verification query, and playbook sequencing are authoring conventions
enforced by review — the checklist lives with the scripts in
[the DataMigrations README](../databases/AppDb/Scripts/DataMigrations/README.md).
