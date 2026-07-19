# Provisioning

Standing up the environments from zero — the *why* behind the exact commands in
[../infra/terraform/README.md](../infra/terraform/README.md): what provisioning owns, where it
stops, and how the estate grows or retires.

## What gets provisioned

The estate is **workspace-per-database**. Each environment declares its databases as a map, and
every entry becomes its own Fabric workspace holding one SQL database:

- A **Fabric workspace** per database, attached to a capacity.
- One **empty SQL database** item — empty because Terraform owns the item's *existence*, not
  its contents.
- **Workspace role assignments** granting the deploy identity and the team their access, read
  from code rather than clicked in a portal.
- A **per-environment Entra security group** for read-only access to that database. Its name
  carries the environment (dev and prod readers are distinct groups); it is the handle the
  access model grants against ([security.md](security.md)).

Terraform stops at the item boundary. Schema arrives separately — the `databases/<name>/` SQL
project builds into a dacpac and the deploy pipeline publishes it ([ci-cd.md](ci-cd.md)) — so
provisioning and schema delivery are two clean stages: **Terraform makes the database exist;
build-and-publish makes it match the code.** Everything here is Terraform under
`infra/terraform/`, one tfvars file and one state file per environment.

## Identity setup

The pipelines authenticate as a **user-assigned managed identity** through GitHub OIDC
federated credentials — no app registration, no stored secrets ([security.md](security.md#cicd-identity--federation-not-secrets)).
One-time setup:

```sh
# 1. Create the user-assigned managed identity
az identity create \
  --name "fabric-database-cicd-deploy" \
  --resource-group <RESOURCE_GROUP>

# 2. Add a federated credential per GitHub environment (dev, test, prod)
az identity federated-credential create \
  --name "github-dev" \
  --identity-name "fabric-database-cicd-deploy" \
  --resource-group <RESOURCE_GROUP> \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:<OWNER>/<REPO>:environment:dev" \
  --audiences "api://AzureADTokenExchange"
```

Repeat step 2 with `github-test` / `environment:test` and `github-prod` / `environment:prod`.
The `subject` binds each credential to one GitHub environment, so the prod credential is only
issuable to a job that passed the prod approval gate.

Add one more with subject `repo:<OWNER>/<REPO>:ref:refs/heads/main` (name it e.g.
`github-main-plan`). It exists for the deploy's **pre-approval prod plan**
([ci-cd.md](ci-cd.md)): that job must run *before* the prod gate — so it cannot bind the prod
environment — and only reads (state + a script/report diff). Binding to the `main` ref keeps it
issuable solely to workflows already merged past the PR gate.

> **If the repository was ever deleted and recreated** (even under the same name), GitHub
> issues its OIDC tokens with an *immutable* ID-embedded subject —
> `repo:<owner>@<owner-id>/<repo>@<repo-id>:...` — as a defense against repo-name
> resurrection, and this cannot be customized away. Every federated credential's subject must
> then use that exact prefix (find it in the `AADSTS700213` error of a failed login, or via
> `GET /repos/<owner>/<repo>/actions/oidc/customization/sub`); update the credentials with
> `az identity federated-credential update`.

Then grant the identity what the model needs:

- **Tenant setting** — enable *service principals can use Fabric APIs*
  ([authentication docs](https://learn.microsoft.com/fabric/database/sql/authentication)); a
  Fabric admin-portal setting, without which nothing below works.
- **Capacity access** — Terraform references an *existing* capacity, so the identity needs the
  **capacity Contributor** role to create workspaces and assign them (Admin portal → Capacity
  settings → *Contributor permissions*, via a security group). This works on a paid
  **F-SKU / P-SKU** capacity but **not on a Fabric _trial_ capacity**, which cannot grant a
  service principal capacity rights
  ([capacity settings](https://learn.microsoft.com/fabric/admin/capacity-settings)). On a trial
  capacity, provision locally with your own `az login` (you are the trial's capacity admin) and
  give the deploy identity a workspace role via `additional_role_assignments`, so the pipeline
  can still publish.
- **State access** — **Storage Blob Data Contributor** on the remote-state container, so the
  backend reads and writes state over Entra auth.
- **Directory write for the reader group** — the Microsoft Graph **`Group.Create`** permission
  (or the Groups Administrator role), because Terraform creates the reader group. More than the
  read-only directory access the rest needs, so grant it deliberately.

The CI environment variables that carry this identity into Terraform are in
[../infra/terraform/README.md](../infra/terraform/README.md#authentication).

## What Terraform owns

`infra/terraform/` uses the
[microsoft/fabric provider](https://registry.terraform.io/providers/microsoft/fabric/latest)
for Fabric items and the **azuread** provider for the reader group; **azurerm** is the state
backend only. The root `for_each`es one module over the `databases` map, so each database gets
its own workspace. Within a database:

- **The capacity** is referenced, not created — a data source resolves the existing capacity
  each workspace is assigned to.
- **The workspace and SQL database** are native fabric resources. Creation-time-only properties
  (collation) are set here because they cannot change afterward — a change to them recreates
  the database.
- **The reader group** is an azuread security group, one per database per environment; the
  post-deploy script wires its contained user inside the database.
- **Workspace role assignments** grant other principals their roles. The workspace creator is
  granted Admin automatically, so `additional_role_assignments` is for *other* principals —
  listing the deploy identity there collides with its implicit grant.
- **Operator access** (`workspace_operators`) grants the same principals a role on **every**
  workspace in the environment. This matters on the CI path: when the deploy identity
  provisions the estate, it is the *only* principal on each new workspace — no human can see
  them, and the item-share step below is impossible — until an operator grant exists. Point it
  at a security group (create one Entra group, manage people by membership) rather than
  individuals; per-database one-offs still belong in `additional_role_assignments`.
  **Create the group well before provisioning**: Fabric's evaluation of a *freshly created*
  group's membership can lag by an hour or more, during which members see nothing despite the
  role assignment existing — a pre-existing, already-used group avoids the wait.
- **Prod provisioning pauses at the prod gate.** `provision.yml` binds the target GitHub
  environment, so a prod plan/apply waits for the same required reviewer as a prod deploy —
  by design (infrastructure changes to prod deserve the same gate), but plan for the pause.

Outputs are keyed by the `databases` map key. The deploy reads them straight from state at run
time — nothing is copied into GitHub, so **provisioning is the single source of truth** for
endpoints and reader-group identity. The exact outputs, command sequence, backend config, and
static checks are in [the Terraform README](../infra/terraform/README.md#outputs).

## What Terraform cannot reach

Terraform ends at the item boundary. Two things live past it.

**Database-scoped settings** applied via T-SQL live in
`databases/<name>/Scripts/PostDeployment/` as idempotent, state-guarded statements
([conventions.md](conventions.md#post-deployment-scripts)) and deploy with the schema — so
configuration is versioned and converged on every publish. The split: **Terraform owns
existence, PostDeployment owns behavior, and creation-time-only properties belong to Terraform
because nothing else gets a chance.**

**The reader group's connect grant.** Creating the group and granting it `SELECT` is not
enough — in Fabric the permission to connect comes only from the Fabric layer, never a SQL
grant ([security.md](security.md)). So someone **shares the database item** with the group at
the **Read** item permission. It is an item share, not a workspace role and not an
`additional_role_assignments` entry, and there is no public REST API for granular item sharing —
it is done in the Fabric portal:

1. Open the workspace and select the **SQL database** item.
2. Use **⋯ → Manage permissions** → **Add user** (or the item's **Share** action) — the portal
   opens a **"Grant people access"** dialog.
3. Enter the environment's reader group — e.g. `Fabric AppDb Readers [dev]`.
4. Leave every **"Additional permissions"** checkbox **unchecked** — especially *"Read all data
   using SQL database"* (`ReadData`) and *"Read all data using SQL analytics endpoint"*. Those
   grant blanket read of **all** data at the Fabric layer, bypassing the SQL-scoped
   `app_reader` model this repo builds. The plain share with no boxes is exactly the connect
   grant (the dialog's own footer says the same: define database permissions with GRANT/DENY
   in T-SQL).
5. **Grant**. The group can now connect, and the schema-scoped role (`app_reader`) decides what
   it sees.

## GitHub configuration

1. Create three GitHub **environments**: `dev`, `test`, `prod`.
2. Add a **required reviewer** to `prod` — the approval gate the deploy pipeline pauses on.
3. Set these GitHub Actions **variables** (identifiers, not secrets — OIDC means there are no
   secrets to set). SQL endpoints and reader-group identity are not among them; the deploy
   reads those from Terraform state.

   **Repository-level** (one deploy identity + state backend, shared by every environment):

   | Variable | Value |
   |---|---|
   | `AZURE_CLIENT_ID` | the deploy identity's client (application) ID |
   | `AZURE_TENANT_ID` | your Entra tenant ID |
   | `AZURE_SUBSCRIPTION_ID` | the identity's subscription ID |
   | `TFSTATE_STORAGE_ACCOUNT` | remote-state storage account |
   | `TFSTATE_CONTAINER` | remote-state container |

   **Per-environment** (set inside each of `dev` / `test` / `prod`):

   | Variable | Value |
   |---|---|
   | `TFSTATE_KEY` | this environment’s state file; prefix it with the repo name for provenance in a shared container, e.g. `fabric-sql-database-cicd/dev.tfstate` |
   | `FABRIC_CAPACITY_NAME` | the Fabric capacity this environment uses, by **display name** — the normal path on a paid F-SKU (the deploy identity resolves it and validates it is Active). Set this **or** `FABRIC_CAPACITY_ID`, not both |
   | `FABRIC_CAPACITY_ID` | the capacity by **ID** — for capacities the identity can't enumerate by name (e.g. a trial). There also set `SKIP_CAPACITY_STATE_VALIDATION=true`, which turns off the Active check the name path performs |
   | `TF_DATABASES` | the databases map as JSON, e.g. `{"AppDb":{}}` |
   | `TF_WORKSPACE_OPERATORS` | optional — operator principals granted a role on **every** workspace, as JSON, e.g. `{"team":{"principal_id":"<group-object-id>","principal_type":"Group","role":"Admin"}}` (see below) |
   | `SKIP_CAPACITY_STATE_VALIDATION` | optional — `true` for a trial capacity |
   | `TF_BACKUP_RETENTION_DAYS` | optional — PITR retention (bounds in [variables.tf](../infra/terraform/variables.tf)) |

## Adding a database

The module and the `for_each` are already in place, so growth costs a map entry, not a
refactor. A new database lines up two things:

- **A `databases` map entry**, added to *every* environment's tfvars and kept identical — same
  keys in dev, test, and prod. Per-environment differences belong in defaults or per-database
  overrides, not in which databases exist.
- **A `databases/<name>/` SQL project** — created with the
  [SQL Database Projects tooling](https://learn.microsoft.com/sql/tools/sql-database-projects/sql-database-projects)
  (or imported from an existing database via *Create Project from Database*), then slimmed to
  a minimal `.sqlproj` inheriting its target platform and rules from
  `databases/Directory.Build.props`.

The repo-wide build discovers the project by glob and the path-filtered deploy picks it up; the
full contract and the per-database override fields are in
[the Terraform README](../infra/terraform/README.md#multiple-databases).

## First deploy after provisioning: let the workspace settle

Provisioning is fast (a workspace and its SQL database create in well under a minute), but a
**brand-new workspace's access does not become usable instantly.** Terraform grants the deploy
identity its workspace role the moment the workspace exists, yet Fabric propagates that grant to
the **SQL data plane** asynchronously — usually a few minutes, occasionally much longer. Deploy
too soon and SqlPackage fails to connect with *"Login failed … Verify the user has the Read item
permission,"* even though the role assignment is correct.

So the first deploy to a newly provisioned database is naturally sequenced *after* provisioning,
not chained onto it:

- The deploy waits it out. `deploy-env.yml` polls the endpoint for up to 15 minutes before
  publishing (steady-state deploys pass instantly), so a first deploy that starts a little early
  just waits rather than failing.
- If it still times out, **re-run the deploy** a few minutes later — propagation is eventual.
- If it persists unusually long, force the sync by **re-applying the deploy identity's workspace
  role assignment** (remove and re-add it — via a `terraform apply` that recreates it, or the
  Fabric portal). Note the recreate is a delete+create, so a CI apply needs
  `confirm_destroy=true` to pass the destroy guard. This reliably kicks a stuck grant; see
  [operations.md](operations.md#recovering-deploy-access-to-a-new-workspace).

This is a Fabric platform behavior, not a pipeline fault — plan a short settle window between
standing up a new environment and its first deploy.

The same login error on an *already-working* database is a different problem — capacity
throttling ([operations.md](operations.md#throttling-can-masquerade-as-the-same-login-failure)).
Provisioning itself consumes capacity: on small SKUs (F2/F4), standing up several workspaces
and databases back-to-back can throttle enough that a creation times out (`context deadline
exceeded` from the provider — `provision.yml` retries that signature once automatically, after
a pause and a re-run of the destroy guard). If it recurs, space the environments out or
suspend/resume the capacity ([operations.md](operations.md#throttling-can-masquerade-as-the-same-login-failure)).

## Decommissioning

Retiring a database is a procedure, not a deletion:

1. **Final archival export.** Export a `.bacpac` with SqlPackage's
   [Export action](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-export) and tag
   it for your retention obligations — the platform holds backups only for the retention
   window, so long-term retention is yours to own. Keep the file somewhere durable off the
   capacity.
2. **Announce a sunset date** to consumers and run a read-only grace period.
3. **Tear down.** Remove the database's `databases` map entry (in every environment), delete
   its `databases/<name>/` folder, and `terraform apply` — its workspace, database, and reader
   group come down together.
