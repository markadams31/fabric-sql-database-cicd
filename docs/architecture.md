# Architecture

Why the solution is built this way: what Microsoft's platform owns, what this repo owns, and
the reasoning behind the decisions a reviewer questions first.

## The system

```
                  ┌──────────────────────────────────────────────┐
                  │                 GitHub repo                  │
                  │  SQL project · Terraform · workflows · docs  │
                  └───────┬──────────────────────┬───────────────┘
                          │  OIDC → user-assigned managed identity
                          │        (no stored secrets)
             ┌────────────▼─────────┐   ┌────────▼─────────────────┐
             │ Terraform            │   │ GitHub Actions           │
             │ providers:           │   │  lint + build (PR gate)  │
             │  fabric  (workspaces,│   │  provision (empty DBs)   │
             │   databases, roles,  │   │  build once → promote    │
             │   reader groups)     │   │   dev → test → prod      │
             │  azuread (groups)    │   │   (SqlPackage, data-loss │
             │ azurerm = state      │   │    gated, plan-approved) │
             │  backend only        │   └────────┬─────────────────┘
             └──────────────────────┘            │
                                                 │
  ┌──────────────────────── Microsoft Fabric ────▼───────────────────────────┐
  │        Entra-only auth · workspace roles · capacity-backed compute       │
  │                                                                          │
  │  ┌─ dev workspace ─┐  ┌─ test workspace ─┐  ┌─ prod workspace ────────┐  │
  │  │ SQL database    │  │ SQL database     │  │ SQL database            │  │
  │  │ first deploy    │  │ staging gate     │  │ approval-gated          │  │
  │  │ target          │  │                  │  │                         │  │
  │  │                 │  │                  │  │                         │  │
  │  │ app_reader ←────┼──┼──────────────────┼──┤ per-env Entra reader    │  │
  │  │ (schema read)   │  │                  │  │ group (item Read share) │  │
  │  └─────────────────┘  └──────────────────┘  └───────────┬─────────────┘  │
  │                                                         │ automatic      │
  │                                          ┌──────────────▼─────────────┐  │
  │                                          │ OneLake replica (delta) →  │  │
  │                                          │ SQL analytics endpoint     │  │
  │                                          └────────────────────────────┘  │
  └──────────────────────────────────────────────────────────────────────────┘
```

Three environments, one artifact. Terraform stands up the workspaces, databases, role
assignments, and each database's per-environment reader group
([provisioning.md](provisioning.md)) with the `fabric` and `azuread` providers; `azurerm` is
present only as the remote-state backend. GitHub Actions runs the PR-validation gate (lint and
build), provisions the empty databases, and promotes one build dev → test → prod — planning
each change as the exact migration T-SQL with its data-loss consequences, pausing prod's
approval on that plan, and refusing to publish if the target drifted from what was approved;
SqlPackage's data-loss block backstops it all ([ci-cd.md](ci-cd.md)). Production data
replicates automatically to OneLake for analytics ([operations.md](operations.md)).

## The SaaS boundary

The design is explicit about the boundary in both directions.

**What Microsoft manages is consumed and verified, not rebuilt** — backup execution, integrity
checking, high availability, patching, automatic tuning
([platform](https://learn.microsoft.com/fabric/database/sql/overview)). The repo's job here is
verification: backup recency is monitored, restore is rehearsed. A platform guarantee you have
never exercised is an assumption, not a control.

**What the platform does not provide is engineered deliberately** — reviewable migrations,
gated change control, and a practiced rollback path. Backups also stay
[in-region](https://learn.microsoft.com/fabric/database/sql/backup): cross-region protection
is the operator's to own, via a bacpac export ([ci-cd.md](ci-cd.md)). Nothing here duplicates
the platform, and nothing assumes the platform covers what it doesn't.

## Design tenets

Each tenet names the mechanism that enforces it — an unenforced principle is a poster.

1. **The repo is the only source of truth.** Changes reach a workspace only through the repo,
   build, and PR gate. No human holds a write-capable workspace role, so there is nothing to
   edit in the portal; a portal edit is drift, reverted or adopted through a PR, never merged
   upward silently.
2. **Nothing hand-written that can be generated.** Migration scripts come from the SqlPackage
   diff; the deploy record comes from the same pipeline run.
3. **Conventions are defined as rules and checked.** If tooling doesn't enforce it, assume it
   will be violated — so conventions live as build-integrated code-analysis rules and source
   linting, not review etiquette ([conventions.md](conventions.md)).
4. **Schema changes and data migrations are different risk classes.** Schema diffs are gated by
   SqlPackage's data-loss block; data migrations are explicit, reviewed scripts that run as
   their own step ([data-migrations.md](data-migrations.md)).
5. **No destructive change without a human and a pre-deploy export.** A data-loss change is
   blocked unless a reviewer deliberately overrides it; the prod export precedes every publish
   regardless. The prod reviewer approves a *specific, fingerprinted plan* — generated against
   live prod before the gate and re-verified after it — never a blind promotion
   ([ci-cd.md](ci-cd.md)).
6. **One artifact, promoted.** The dacpac published to prod is byte-identical to the one tested
   in dev and test, stamped with its version and commit.
7. **Respect the SaaS boundary in both directions.** Don't rebuild what the platform owns;
   don't assume it covers what it doesn't.
8. **Recovery paths are rehearsed.** An untested restore is a hope — every path back is a drill
   before an incident forces it ([ci-cd.md](ci-cd.md#recovery)).
9. **Growth follows the paved road.** Adding a database is a `databases/<name>/` folder plus
   one entry in the Terraform databases map; adding an environment is a module instantiation,
   not a bespoke effort ([provisioning.md](provisioning.md)).

## Identity and access

Authentication is **Microsoft Entra only** — no SQL logins, no server principals, no passwords
to store or rotate. The pipelines authenticate as a **user-assigned managed identity** through
GitHub OIDC federated credentials (one per environment, plus a read-only main-branch credential
for the pre-approval prod plan), so no client secret exists anywhere.

Authorization has **two cooperating layers**: the Fabric layer (workspace roles, item
permissions) decides who can *connect* — a SQL `GRANT` alone never lets a principal in — and
the SQL layer (roles and grants, deployed as code) decides what they can *do*. The deploy
identity holds the only write-capable role, so humans read and the repo stays the single source
of truth. The full model — the scoped-reader chain, principals, the OIDC
approval-to-credential chain, grants-target-roles — is [security.md](security.md).

## Hardening options

The baseline is Entra-only authentication over TLS with platform encryption at rest.
Organizations with stricter postures layer on
[customer-managed keys](https://learn.microsoft.com/fabric/database/sql/encryption) for
workspace encryption,
[dynamic data masking](https://learn.microsoft.com/sql/relational-databases/security/dynamic-data-masking?view=fabric-sqldb)
for non-privileged read paths,
[SQL audit](https://learn.microsoft.com/fabric/database/sql/auditing) to OneLake, and
[tenant-level Private Link](https://learn.microsoft.com/fabric/security/security-private-links-overview)
for network isolation of the SQL endpoint. These are options rather than baseline because
network and compliance postures differ per organization; the pipeline works unchanged with any
of them.

Enabling CMK adds one recovery trap: an old Key Vault key version purged before the retention
window elapses leaves the backups it encrypted unrestorable
([ci-cd.md](ci-cd.md#customer-managed-keys-and-backups)).

## Decision log

| Decision | Alternatives considered | Why this one |
|---|---|---|
| SqlPackage promotion | Fabric-native [deployment pipelines](https://learn.microsoft.com/fabric/database/sql/deployment-pipelines) | Four things the native path doesn't give: a dry-run script as a reviewable artifact (the exact T-SQL, before it runs); a data-loss gate that is the tool's, not a bespoke classifier; build-once artifact promotion rather than stage-to-stage deploy; and convention gates that run inside the build where the artifact is produced. Fabric git integration can still sit alongside as a drift tripwire. |
| One example database, generalized via shared build props | A single bespoke project, or a heavyweight multi-database template estate | A database is a minimal `databases/<name>/` folder that inherits target platform, analysis, and rules from `databases/Directory.Build.props`; delete the demo and drop in your own — many databases, zero per-project boilerplate ([provisioning.md](provisioning.md)) |
| Conventions as build-integrated code-analysis rules | Bespoke lint scripts and a hand-rolled `model.xml` checker | Rules run inside `dotnet build` through the DacFx analyzer API — built-in and community rules plus this repo's custom rules in `analyzers/FabricSqlRules` — so a violation reports identically in hooks, locally, and in CI; the rule set lives in `databases/Directory.Build.props` ([conventions.md](conventions.md)) |
| Local validation is the two commands CI runs, wired as git hooks | A manual local-CI orchestrator, or a SQL Server container as a local Fabric proxy | `sqlfluff lint databases` and `dotnet build build.proj` are the whole check; the build compiles against the Fabric target and runs every rule, so there is no bespoke script to drift and no emulator whose fidelity you must trust ([local-development.md](local-development.md)) |
| Prod approval reviews a saved, fingerprint-verified plan | Approve-then-script (the gate before the plan); per-severity approval environments; PR labels or in-repo consent markers for destructive changes | The reviewer sees prod's exact migration T-SQL and data-loss digest *at the approval pause*, and the leg re-plans after approval, refusing to publish on fingerprint mismatch — the same contract Terraform's saved plans make, built from GitHub's native gate with no extra environments or state ([ci-cd.md](ci-cd.md)) |
| Pre-deploy export as the rollback artifact | Platform point-in-time restore alone | Restore always creates a new database and is bounded by the retention window; an export the pipeline owns is scriptable and drillable ([ci-cd.md](ci-cd.md#recovery)) |
| Pipelines run as a user-assigned managed identity with OIDC federation | An app registration holding a stored client secret | A managed identity with per-environment federated credentials has no secret to rotate or leak; the platform is Entra-only regardless, so the pipeline carries no standing credential either ([provisioning.md](provisioning.md)) |
