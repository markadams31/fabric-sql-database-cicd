# Operations

How the database is observed and operated day to day. The deploy-time story is
[ci-cd.md](ci-cd.md), including the recovery paths ([ci-cd.md](ci-cd.md#recovery)); this page is
the running surfaces and the practices around them.

## Observability surfaces

**Query Store.** [Query Store](https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=fabric-sqldb)
is on and its configuration is largely fixed — treat it as always available. It is the primary
evidence for the weekly performance review: plan changes, regressed queries, forced-plan
candidates.

**Performance Dashboard.** The [Performance Dashboard](https://learn.microsoft.com/fabric/database/sql/performance-dashboard)
in the Fabric portal is the live triage surface: CPU and memory timelines with unhealthy
markers; tabs for high-CPU, longest-running, most-frequent, and high-read queries; a
blocked-queries view; automatic-index history; and built-in alerting on CPU, allocated size,
and blocking.

**Capacity Metrics app.** The [Fabric Capacity Metrics app](https://learn.microsoft.com/fabric/enterprise/metrics-app)
shows capacity utilization, smoothing, and throttling. On this platform the capacity is a
first-class suspect in any incident — a database can be healthy while its capacity is throttled
by a neighbor — so it is both a triage input and the source for the weekly utilization trend.

**Audit logs.** [SQL audit](https://learn.microsoft.com/fabric/database/sql/auditing) writes to
OneLake, queryable in place with `sys.fn_get_audit_file_v2`. Review privileged actions,
failed-authentication patterns, and permission changes; an audit trail that has silently
stopped is itself a finding. Because auth is Entra-only, every entry is a directory identity —
a contained user, not a SQL login.

**What's deployed where.** Two independent answers, and they should agree:

- *Database-side (authoritative).* Every deploy stamps the dacpac version onto the target
  database as an extended property, so an operator connected to any environment can ask the
  database directly:

  ```sql
  SELECT CONVERT(NVARCHAR(128), value) AS DeployedDacVersion
  FROM sys.extended_properties
  WHERE class = 0 AND name = N'DeployedDacVersion';
  ```

  Run it against dev, test, and prod to see each environment's live version side by side. The
  version is `1.0.<deploy-run-number>`; the run number ties it back to the exact GitHub Actions
  run that built and promoted that artifact. A sibling property, `DeployedSourceHash`, is the
  deploy's no-op-skip marker (a hash of the database's deploy-relevant sources, stamped after
  the data migrations complete) — it explains a leg reporting "skipped, already up to date"
  while the run is green ([ci-cd.md](ci-cd.md)).
- *Pipeline-side.* GitHub records a Deployment per environment. The repo's **Environments** page
  (and `gh api repos/<owner>/<repo>/deployments`) shows the latest commit deployed to dev/test/
  prod and when — the build-once/promote view, without connecting to a database.

Because one artifact is promoted unchanged dev → test → prod, a version that differs between
environments is expected mid-promotion (prod trails dev) and a *stuck* difference is a signal to
investigate.

## Triage: capacity or engine?

The first fork in any performance incident:

```
Symptom: slow, timing out, or erroring
├─ Capacity Metrics app: is the capacity throttled?
│   ├─ yes → capacity problem. Identify the consumer — this database or a
│   │        neighbor — then review capacity sizing and per-database caps.
│   └─ no  → engine problem ↓
└─ Engine path:
     Performance Dashboard  → what is hot right now?
     Query Store            → did a plan change?
     DMVs                   → live blocking chains
                              (sys.dm_exec_requests, sys.dm_tran_locks)
```

One platform-specific rule before either path: a slow *first* connection after a quiet period
is auto-resume latency, not a regression. This is a
[serverless database](https://learn.microsoft.com/fabric/database/sql/overview) — it pauses
when idle and resumes on the next connection, and the connection that triggers the resume pays
for it. Check whether the symptom survives a warm connection before opening an investigation.

## What consumers must assume

The platform pauses, resumes, scales, and fails over beneath the application. Every consumer
follows this contract:

- Retry transient errors with exponential backoff and jitter.
- Make write retries idempotent — a retried statement must not double-apply.
- Use pool validate-on-borrow or fast eviction, so a resume or failover surfaces as a
  reconnect, not a burst of dead connections.
- Set timeouts that distinguish a slow query from a resuming database — the first connection
  after idle is slow by design.

## Analytics offload

The platform [automatically replicates](https://learn.microsoft.com/fabric/database/sql/mirroring-overview)
operational data to OneLake in delta format, queryable through the SQL analytics endpoint — so
reporting reads the mirror, never the operational endpoint. All supported tables replicate with
no per-table opt-in; tables or columns outside the
[documented limitations](https://learn.microsoft.com/fabric/database/sql/mirroring-limitations)
are skipped rather than stalling the mirror. Replication can be
[stopped and restarted programmatically](https://learn.microsoft.com/fabric/database/sql/start-stop-mirroring-api) —
pause it around a heavy data migration so analytics sees one clean transition instead of hours
of churn ([data-migrations.md](data-migrations.md)).

## Break-glass

There is a defined, time-boxed elevation path for the case where the pipeline itself is the
problem: a temporary grant of emergency access that expires automatically, with every use
opening an incident reviewed afterward against the audit trail. It is affordable precisely
because no human holds standing write: the deploy managed identity is the only write-capable
principal, so break-glass is the sole route to a manual change.

## Recovering deploy access to a new workspace

A **freshly provisioned** workspace occasionally leaves the deploy identity unable to connect to
its SQL database — SqlPackage reports *"Login failed … Verify the user has the Read item
permission"* even though Terraform granted the workspace role. This is Fabric's asynchronous
propagation of a workspace role to the SQL data plane, not a misconfiguration ([provisioning.md](provisioning.md#first-deploy-after-provisioning-let-the-workspace-settle)).

Resolution, in order:

1. **Wait and re-run the deploy.** Propagation is eventual and usually completes within minutes;
   the deploy's own readiness wait absorbs the common case.
2. **Force the sync** if it persists: remove and re-add the affected principal's workspace role
   assignment. Via Terraform this takes **two applies** — first remove the
   `additional_role_assignments` entry and apply, then re-add it and apply. A single apply that
   renames the entry's key does NOT work: Terraform orders the create before the destroy and
   Fabric rejects it with `PrincipalAlreadyHasWorkspaceRolePermissions` (verified empirically).
   In CI each removal counts as a destroy, so pass `confirm_destroy=true`. The portal
   equivalent (Workspace → Manage access, delete then re-add) also works.

This only affects the *first* deploy to a new workspace; once access propagates it stays put.

## Throttling can masquerade as the same login failure

The identical error — *"Login failed … Verify the user has the Read item permission"* — has a
second, unrelated cause: **capacity throttling**. When the capacity's smoothed compute debt
crosses the rejection threshold, Fabric
[rejects new SQL connections](https://learn.microsoft.com/fabric/data-warehouse/compute-capacity-smoothing-throttling)
and the gateway reports the rejection as a permission-validation failure. The permission is
fine; the validation call itself is being refused.

Distinguish the two by history: a database that **deployed successfully before** and suddenly
refuses the same identity is throttled, not misconfigured — especially right after a burst of
Fabric operations (several publishes, workspace creates or destroys, a heavy backfill). The
deploy workflow's readiness wait prints the client error on each attempt for exactly this
triage, backing off 30→60→120s up to a deliberate 15-minute ceiling — a leg holding at 120s
intervals and then failing is that ceiling, not a hang. Confirm in the Capacity Metrics app
(the triage fork above).

Resolution: let the debt burn down and re-run, or **suspend and resume the capacity** (clears
accumulated smoothing debt immediately; the overage is billed). If it recurs under normal
cadence, the capacity is undersized for the estate.

A third cause exists and is distinguishable in one check: a **platform authorization incident**.
If the role assignments verifiably exist (Fabric admin API:
`GET /v1/admin/workspaces/{id}/users`) yet logins still fail — for a principal that worked
before, across environments, and a capacity suspend/resume does not clear it — the fault is the
platform's authorization backend, not this repo's configuration. Observed in practice affecting
users and service principals for hours at a time, roaming across databases. There is no
operator remedy beyond waiting and re-running; resist the urge to "fix" configuration that the
admin API shows is already correct. (The deploy's readiness wait fails fast — 5 minutes — for
databases that have deployed before, since role propagation is impossible for them and waiting
longer rarely helps the other causes.)

```sh
CAP=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Fabric/capacities/<name>
az resource invoke-action --ids "$CAP" --action suspend
az resource invoke-action --ids "$CAP" --action resume
az resource show --ids "$CAP" --query properties.state -o tsv   # expect: Active
```

The same two actions are also the cost lever for a test capacity — a paused F-SKU does not
bill. Suspend it between test sessions and resume before the next provisioning or deploy run.

Sizing note from operating this pipeline: the smallest SKUs (F2/F4) sustain a single database
at light cadence, but one full dev → test → prod promotion of even a two-database estate can
accumulate enough debt that the later legs are rejected. Plan real multi-environment estates on
a larger SKU, or pace deploys and provisioning apart.

## Operations calendar

| Cadence | Activity |
|---|---|
| Weekly | Query Store review, audit-log review, capacity utilization trend |
| Monthly | One recovery drill ([ci-cd.md](ci-cd.md#recovery)), timed against its target |
| Quarterly | Capacity sizing review |

A Fabric restore always creates a *new* database, so the drill includes the rebuild-and-redirect
cutover, not just the restore ([ci-cd.md](ci-cd.md#recovery)).
