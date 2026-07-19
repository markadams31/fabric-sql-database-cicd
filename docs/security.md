# Security Model

The complete access-and-identity model. Other docs reference this page rather than restating
it. It answers: **who can reach a database, what can they do once in, and how is that granted
without storing a secret?**

## The shape of it

Three facts carry the model:

1. **Two questions, two layers.** Access is *"can you connect?"* then *"what can you do once
   connected?"* — answered by different systems. Connection is a **Fabric** decision (workspace
   roles and item permissions). What you can do inside is a **SQL** decision (database roles and
   `GRANT`/`DENY`). The asymmetry matters: **the permission to connect can only come from the
   Fabric layer.** A SQL `GRANT` alone never lets a principal in — the connection is refused
   before any SQL permission is consulted.
2. **Every identity is Microsoft Entra.** Fabric SQL has no SQL logins and no server-level
   principals. Every principal — person, group, or workload — is an Entra identity surfaced
   inside the database as a *contained user*.
3. **No long-lived secrets.** Every machine-to-cloud hop authenticates with a short-lived token
   obtained at run time through federation. Nothing to rotate, nothing to leak.

## Layer 1 — Fabric access (the way in)

Two Fabric mechanisms grant a path to the database; either confers connect, neither is a SQL
permission.

**Workspace roles** apply to every item in a workspace. On a SQL database:

| Workspace role | Effect on the SQL database |
|---|---|
| Admin | Connect, read, write, and manage the workspace and its access |
| Member | Connect, read, write |
| Contributor | Connect, read, write |
| Viewer | Connect and **read data** only |

**Item permissions** apply to one item, shared directly with a principal. **Read** is the
minimum that grants connect (`ReadData` adds reading data through the TDS endpoint; `Write` and
`Share` add more). Sharing one database's **Read** with a group lets that group connect to that
database only, with no workspace-wide role.

The authoritative matrices are the platform's
([workspace roles](https://learn.microsoft.com/fabric/fundamentals/roles-workspaces),
[SQL database authorization](https://learn.microsoft.com/fabric/database/sql/authorization)).

## Layer 2 — SQL access (what you can do)

Once a principal is in, ordinary SQL authorization applies, managed as code: roles, schemas,
and grants live in each project's `databases/<name>/Security/` folder and deploy with the
schema. Publishes pin `IgnorePermissions=False`, so permissions converge on every deploy
([ci-cd.md](ci-cd.md)). Two rules:

- **Grants target roles, not individuals.** A principal gets access by role membership, so an
  access review is a membership review. This is a team convention, not a build check — in
  Fabric's Entra model a managed identity is indistinguishable from a person at the schema
  level, so no analyzer rule can tell a direct-to-individual grant from a legitimate one.
- **`DENY` wins.** A `DENY` overrides any `GRANT` at any level
  ([permission semantics](https://learn.microsoft.com/sql/relational-databases/security/permissions-database-engine)).

Scoping uses schema-scoped grants: a role granted `SELECT ON SCHEMA::app` reads every table in
`app` and nothing outside it. That is the `app_reader` role the example ships.

## The principals

| Principal | Fabric layer (connect) | SQL layer (do) | Why |
|---|---|---|---|
| **Deploy managed identity** | Workspace **Admin/Member** | Effectively `db_owner` | Runs every deploy; creates schema and provisions users. The **only** writer. |
| **Human operators** | **Viewer**, or item **Read** — granted estate-wide via Terraform's `workspace_operators` | Read (or a scoped role) | People read; the pipeline writes. |
| **Reader group** (per env) | Item **Read** (shared) | `app_reader` (`SELECT` on one schema) | Least-privilege read of exactly one schema. |
| **Application workload** | Item **Read**/**ReadData** | A purpose-built role | Same pattern: an identity in a role, never a direct grant. |

The write/read imbalance is the drift-prevention control. Only the deploy identity can change a
database, so the source tree stays the single source of truth — there is no second path by
which prod can diverge from what is committed. Granting a human `Write` reopens that path;
`Viewer`/`Read` does not.

`workspace_operators` ([Terraform README](../infra/terraform/README.md#multiple-databases))
grants one team group a role on every workspace — necessary because CI-provisioned workspaces
otherwise have the deploy identity as their *only* principal. Its role choice is where the
write/read line is drawn: **Viewer** preserves the model; **Admin** is the pragmatic choice
where operators must manage item shares (an Admin-only action), accepting that it technically
reopens the write path for those people — a deliberate, visible trade recorded in one variable
rather than scattered portal grants.

## The scoped-reader chain

Giving a group read access to **one schema only** deliberately spans both layers, and one step
has no automation. For a reader group that should see `app` and nothing else:

1. **Terraform** creates a per-environment Entra security group and outputs its object id and
   display name. Group membership is managed in Entra, not in this repo.
2. **The post-deployment script** creates the group's contained user in the database by object
   id — `CREATE USER ... WITH SID = <id>, TYPE = X`, because a service-principal deploy
   identity cannot use `FROM EXTERNAL PROVIDER` in Fabric — and adds it to `app_reader`. It is
   driven by SQLCMD variables the pipeline fills from Terraform outputs, and guarded so it
   converges on every publish.
3. **Someone grants the group item Read** on the database — the connect grant, and the one
   manual step. It is an item permission, not a workspace role, so Terraform cannot express it,
   and there is no public REST API for granular item sharing; it is done in the Fabric portal.
   Steps: [provisioning.md](provisioning.md#what-terraform-cannot-reach).

After steps 1–2 the group can `SELECT` but cannot get in; only step 3 grants the connection.
Both are required, from different layers.

Workspace **Viewer** also grants connect + read, but reads **all** data in the workspace, which
defeats single-schema scoping — so scoped read is item-Read-plus-role, never Viewer. Where a
group *should* see everything in a workspace, Viewer is the right tool, and unlike an item
share it can be assigned via the Fabric REST API (Terraform's `additional_role_assignments`).

## CI/CD identity — federation, not secrets

The pipelines authenticate as a **user-assigned managed identity** through **GitHub OIDC
federation**. No client secret exists: at run time the workflow requests a short-lived signed
token from GitHub, and Entra exchanges it for an access token because a **federated
credential** on the identity trusts that exact token.

The trust is scoped per environment. Each federated credential's subject is
`repo:<owner>/<repo>:environment:<env>`, so the **prod** credential is only issuable to a job
running in the `prod` GitHub environment — which is gated by a **required reviewer**. The
chain: a human approves the prod deployment → the job enters the `prod` environment → only then
can it obtain a token → only then can it **write to** prod. Approval is a hard precondition of
holding prod-writing credentials, not a checkbox beside them.

One additional credential is bound to the **`main` branch ref** rather than an environment
(`repo:<owner>/<repo>:ref:refs/heads/main`). It exists for the deploy's pre-approval **prod
plan** ([ci-cd.md](ci-cd.md)): the job that shows the reviewer prod's exact migration script
must run *before* the gate, so it cannot hold the environment-bound credential. The scoping
still holds a hard line — the ref binding means only workflows already merged past the PR gate
can obtain it, and the job only ever *reads* (state, a script/report diff); every write to prod
remains behind the approval-bound credential.

Supporting GitHub-side controls:

- **Environments** (`dev`/`test`/`prod`) carry per-environment variables and, on `prod`, the
  required reviewer and protected-branch deployment policy.
- **Branch protection** on `main` requires a PR and a green build to merge.
- **Least-privilege workflow permissions** — `id-token: write` only on jobs that log in to the
  cloud; build and validation jobs stay read-only.
- **No identifiers or secrets in the repo** — real `*.tfvars`/`*.backend.hcl` are gitignored;
  CI supplies the same identifiers from GitHub Actions variables at run time
  ([provisioning.md](provisioning.md#github-configuration)).

## The Terraform state backend

Remote state lives in Azure Storage, authenticated with **Microsoft Entra data-plane auth**
(`use_azuread_auth`), not a storage key. The identity needs only **Storage Blob Data
Contributor** on the state container, and the backend makes no control-plane calls — which is
what lets the state account live in a different subscription from everything else.

## Platform prerequisites

Granted once, outside the schema; without them the model does not function. Setup lives in
[provisioning.md](provisioning.md) and [infra/terraform/README.md](../infra/terraform/README.md):

- **Tenant setting "service principals can use Fabric APIs"** enabled (it governs managed
  identities too).
- **The deploy identity is a member of each workspace** (Admin/Member) — automatic when the
  identity creates the workspace, an explicit grant otherwise. Missing it, a deploy
  authenticates but is refused with *"verify the user has the Read item permission."*
- **Capacity access** for the identity, to create and assign workspaces.
- **Directory `Group.Create`** (or Groups Administrator), because Terraform creates the reader
  groups — a directory write, more than the read-only access the rest needs.

## Where each control lives

| Control | Source of truth |
|---|---|
| Reader security groups (Entra) | Terraform — [infra/terraform](../infra/terraform) |
| Team/workspace role assignments | Terraform `additional_role_assignments` |
| Contained DB users, SQL roles, grants | `databases/<db>/Security/` + `databases/<db>/Scripts/PostDeployment/` |
| Permissions applied on every deploy | Publish profile `IgnorePermissions=False` — [deploy/fabric.publish.xml](../deploy/fabric.publish.xml) |
| The CI identity and its federation | The managed identity in Entra + GitHub OIDC federated credentials |
| Environments, reviewers, branch protection | GitHub repository settings |
| Item **Read** share for scoped readers | Manual — Fabric portal ([provisioning.md](provisioning.md#what-terraform-cannot-reach)) |
| Identifiers/secrets kept out of the repo | [.gitignore](../.gitignore) + [infra/terraform/.gitignore](../infra/terraform/.gitignore) |
