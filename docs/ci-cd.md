# CI/CD Pipeline

What gates a pull request, what a deploy does, and every path back when one goes wrong.

Two ideas carry the design:

- **One set of checks, two places to run them.** The checks are ordinary commands — lint the
  T-SQL source, build the projects — so they run identically on your machine and in CI. Local
  hooks give fast feedback; the PR gate is authoritative.
- **The gate never touches the cloud.** Validation compiles and analyzes the schema offline.
  Proving a change correct requires no Fabric workspace, so the gate has no credentials to
  leak and no environment to be flaky.

## The PR gate

Every pull request runs two blocking steps
([pr-validation.yml](../.github/workflows/pr-validation.yml)):

1. **Lint** — `sqlfluff lint databases` checks T-SQL source style.
2. **Build** — `dotnet build build.proj` compiles every SQL project against the Fabric target
   platform and runs all code analysis. Unsupported T-SQL fails to compile; rules escalated to
   errors fail the build.

The second step is the whole conventions system — which rules run and at what severity is
[conventions.md](conventions.md)'s territory. The workflow requests only `contents: read`; it
authenticates to nothing because it deploys nothing. The same two commands run locally as git
hooks ([local-development.md](local-development.md)).

## The promotion pipeline

Implemented in [deploy.yml](../.github/workflows/deploy.yml), which promotes one build through
the reusable [deploy-env.yml](../.github/workflows/deploy-env.yml). Provisioning
([provision.yml](../.github/workflows/provision.yml)) creates the empty databases; this
pipeline fills them.

**Build once, promote the same artifact.** One `dotnet build` produces a dacpac stamped with a
version (`DacVersion`, set by CI) and its commit SHA. That exact artifact moves
dev → test → prod, so every environment answers "what is deployed here" from the artifact, and
the thing tested in dev is byte-identical to the thing that reaches prod.

**Only changes deploy.** Two layers keep redundant work (and, on small capacities, redundant
compute burn) near zero:

- *Matrix selection* — a push deploys only the databases whose sources changed since the last
  successful deploy; a change to any shared input (`deploy/`, `build.proj`, the shared
  props/targets, the deploy workflows) deploys all of them, and anything ambiguous falls back
  to all, because a redundant leg is a cheap no-op while a missed leg is drift.
- *Per-leg skip* — every successful deploy stamps a `DeployedSourceHash` extended property (a
  hash of that database's folder, the shared publish inputs, and the SqlPackage version) onto
  the database. A leg whose recomputed hash already matches skips the publish *and* the data
  migrations: they are provably re-runs. The stamp is written only after the migrations
  complete, so an interrupted leg re-runs rather than being marked done.

**Every leg detects drift — including skipped ones.** The publish deliberately ignores objects
the source doesn't declare (`DropObjectsNotInSource=False`), and a hash-skipped leg doesn't
diff at all — so an out-of-band table or view could otherwise survive green runs indefinitely
(verified empirically). Each leg therefore runs a **report-only** diff with
`DropObjectsNotInSource=True` (never applied) before anything else: any drop it *would*
perform is an object the source doesn't declare, and the leg **fails** with the drifted
objects listed in its summary — drift means the repo stopped being the single source of
truth, which is an incident, not a warning. Reconcile by adopting the object into
`databases/<name>/` or removing it from the target (break-glass), then re-run. Users, role
memberships, permissions, and extended properties are excluded from the check — the
post-deployment script and the pipeline's own stamps legitimately manage those outside the
model. (The prod plan fingerprint is unchanged by this: it still guards the *planned change*;
the drift check is what guards the target.)

**Generate and present the migration, never hand-write it.** SqlPackage diffs the dacpac
against each target and emits the migration script — the exact T-SQL the deploy will run —
into the run's job summary and an artifact, together with a **data-loss digest** (the
DeployReport's alerts, e.g. *"The column [x].[y] is being dropped, data loss could occur"*)
so every leg states its own destructive consequences up front. Reviewing a deploy means
reading that summary.

**Prod approves a plan, and only that plan applies.** Before prod's approval gate, a
`prod-plan` job generates each database's prod migration script and digest against the *live*
prod database and writes them to the run summary — so at the moment of approval, the reviewer
is looking at exactly what will change and what data would be lost. The plan's semantic
fingerprint is saved; after approval, the prod leg re-plans against the live target and
**refuses to publish if the fingerprints differ** (the target drifted between review and
apply — re-run the pipeline to review a fresh plan). Plan → approve → verify → apply, the
same contract Terraform's saved plans make. The plan job authenticates through a main-branch
federated credential (no environment binding — binding it would gate the plan behind the
approval it exists to inform) and only ever reads.

**The publish profile is the deploy contract.** Publishes run under fixed safety properties in
[deploy/fabric.publish.xml](../deploy/fabric.publish.xml):

- `BlockOnPossibleDataLoss=True` — a publish that could lose data terminates before touching
  anything. SqlPackage's own check does the gating; nothing hand-classifies the change.
- `DropObjectsNotInSource=False` — never drop what the source didn't declare.
- `IgnorePermissions=False` — permissions are deployed code and converge on every publish.

To ship an intentional destructive change, run the deploy manually: **Actions →
*Deploy (build once, promote)* → Run workflow**, then tick **`allow_data_loss`** (relaxes
dev/test) and/or **`allow_data_loss_prod`** (a separate switch for prod). Relaxing dev/test
does not relax prod, and prod still requires its reviewer. The protection against an
*unintended* drop is not the reviewer's eye but the profile itself: `BlockOnPossibleDataLoss=True`
stops a destructive publish regardless, so nothing lossy reaches prod unless `allow_data_loss_prod`
was set on the dispatch.

**Endpoints come from Terraform state.** At deploy time each job reads its database's SQL
endpoint, name, and reader-group identity from `terraform output` — nothing is copied into
GitHub, so provisioning stays the single source of truth. The reader-group values flow to the
post-deployment script as SQLCMD variables ([security.md](security.md)).

**Prod is gated; databases are isolated.** The prod stage requires a reviewer on the `prod`
GitHub environment and takes a pre-deploy bacpac export as its rollback artifact before
publishing. Each database deploys as its own matrix leg: one database's failure or pending
approval never blocks another. On dev/test a newer deploy of the same (database, environment)
supersedes an in-flight one; **prod legs are never cancelled** — a newer run queues behind an
in-flight (or gate-parked) prod leg rather than killing it mid-publish or mid-migration.
Promotion to the next environment waits for all databases in the current one, and every job
carries a finite timeout so a hung leg fails rather than holding its slot for hours.

**Transients are retried; success is verified.** Before anything runs, a readiness wait polls
the database (up to 15 minutes, backing off 30→60→120s) until it accepts the deploy identity —
absorbing both fresh-workspace access propagation and capacity throttling, and printing the
client error each attempt so the two are distinguishable
([operations.md](operations.md#throttling-can-masquerade-as-the-same-login-failure)). Fabric
SQL is also serverless, so the first connection after idle can fail while the database
resumes — every SqlPackage and sqlcmd call retries with backoff rather than failing the
deploy. After the publish, a smoke check connects and asserts the schema is present; a publish
that "succeeded" but left the database unreachable or empty fails the leg immediately.

**Data migrations run last** — the database's `Scripts/DataMigrations/*.sql`, in name order,
on every deploy ([data-migrations.md](data-migrations.md)).

**No stored credentials.** Every cloud step authenticates through GitHub OIDC federation to a
managed identity, with the prod credential issuable only inside the approved `prod`
environment ([security.md](security.md#cicd-identity--federation-not-secrets)).

**Runtime testing is optional and additive.** The gate compiles and analyzes; it does not
execute schema against a live engine. Behavioral tests are a standard `dotnet test` project
against a dev workspace, added as its own stage if you want them.

## What the platform provides

Consumed, not configured
([backup documentation](https://learn.microsoft.com/fabric/database/sql/backup)):

- **Automatic backups** — weekly full, differentials through the day, log backups every few
  minutes. The schedule is fixed and the files are inaccessible; the only interface is restore.
- **Point-in-time restore** within a retention window (retention is configurable per
  database — see [variables.tf](../infra/terraform/variables.tf)).
- **In-region redundancy only.** Backups replicate across availability zones in the primary
  region; there is no geo-redundant copy and no cross-region restore.
- **Backup recency is observable** via the `sys.dm_database_backups` DMV — verify the
  guarantee rather than assuming it.

One caveat: a bacpac is a logical export and is not transactionally consistent against a busy
database — the platform's own guidance says it
[is not a backup substitute](https://learn.microsoft.com/fabric/database/sql/sqlpackage).
Verify any export you intend to rely on by importing it.

## Restore semantics

The platform facts that shape every recovery plan
([restore documentation](https://learn.microsoft.com/fabric/database/sql/restore)):

- **A restore always creates a new database** — you cannot restore over an existing one, so
  every restore implies a cutover: point consumers at the new database, reconcile, retire the
  old.
- **Same workspace, same region only.** Point-in-time restore crosses neither boundary.
- **Restore is automatable** via the Fabric REST API as a database-creation mode
  ([reference](https://learn.microsoft.com/rest/api/fabric/sqldatabase/items/create-sql-database)),
  under the deploy identity — a restore can be a script, not a portal walkthrough.
- **Deleted databases may be recoverable** through the workspace recycle bin, but that depends
  on tenant configuration — check
  [retention and recovery](https://learn.microsoft.com/fabric/admin/retention-recovery) rather
  than assuming.
- **Deleting a workspace destroys its databases.** Treat it as unrecoverable: Terraform owns
  workspace lifecycle, and nothing routine has permission to delete one.

## Recovery

```
Something is wrong after a deploy.
│
├─ Schema-only damage, data intact, cause understood?
│   ├─ yes → FIX FORWARD: a new PR through the normal pipeline. First choice —
│   │        it keeps every control in play.
│   │        Speed matters more? RE-PUBLISH the previous versioned dacpac;
│   │        it is still in the artifact store, and publish is idempotent.
│   └─ no ↓
│
├─ Data corrupted or lost by the change?
│   ├─ Scoped and recent, pre-deploy export exists →
│   │     IMPORT the export into a new database, cut consumers over,
│   │     reconcile anything written since the export.
│   └─ Broader damage, or the export predates too much →
│         POINT-IN-TIME RESTORE to just before the deploy (new database,
│         same workspace), then cut over.
│
└─ Workspace lost?
      Rebuild it with Terraform (provisioning.md), re-publish the current
      dacpac, IMPORT the most recent export.
```

The ordering is deliberate: fix-forward keeps the pipeline's gates, re-publish keeps its
artifact discipline, and import/restore work but cost a cutover. Rehearse each path before an
incident forces it, and time the rehearsals — the measured restore-and-cutover duration is
your actual RTO, whatever the documentation implies.

## Customer-managed keys and backups

If workspace encryption uses
[customer-managed keys](https://learn.microsoft.com/fabric/database/sql/encryption), backups
are encrypted with the key version current when each backup was taken. **Old key versions must
remain available in Key Vault for the entire retention window, or those backups become
unrestorable.** Keep purge protection on and never purge a key version younger than the
retention window — this is the one hardening option whose misconfiguration silently destroys
the recovery story.
