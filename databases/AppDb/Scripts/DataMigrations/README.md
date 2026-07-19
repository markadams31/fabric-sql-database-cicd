# DataMigrations scripts

Idempotent, batched, state-guarded scripts that rewrite data at scale — backfills and the
like. They are **not** part of the compiled model; the pipeline runs **every** script in this
folder, in name order, on every deploy that publishes — there is no applied-history table
(unchanged legs skip via the deploy's source-hash check). Each script must:

- be safe to re-run after it has already applied **and** after a partial failure (state-guarded
  writes, no bare `INSERT … SELECT`),
- write in bounded batches with a brief pause,
- declare its batch size and pacing in a header comment,
- ship with a verification query you run and review before the contract merge — not something
  the pipeline enforces.

**Prune a script once it has applied to every environment.** Because they re-run on every deploy,
a finished migration is dead weight — and one that reads a column a later change drops will fail
every deploy until you remove it.

See [../../../../docs/data-migrations.md](../../../../docs/data-migrations.md) for the full
expand → backfill → cut over → contract playbook.
