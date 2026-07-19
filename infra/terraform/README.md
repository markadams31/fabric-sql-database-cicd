# Terraform — Fabric provisioning

Provisions the databases for an environment — **one Fabric workspace per database**, each
holding one SQL database item plus its role assignments — against an **existing** Fabric
capacity. Also creates, per database, the per-environment Entra security group used for scoped
read access. Databases are declared as a map; adding one is a single map entry. State lives in
an existing Azure Storage account, one state file per environment. The lifecycle reasoning
(what provisioning owns, growth, decommissioning) is [../../docs/provisioning.md](../../docs/provisioning.md);
this page is how to run it.

## Providers

- **`fabric`** — the workspace, the SQL database item, and the role assignments.
- **`azuread`** — the per-environment reader security group (a directory object, which is why
  the identity needs a directory write permission — see [Prerequisites](#prerequisites)).
- **`azurerm`** — the state **backend only**; no `azurerm` resources are managed. The state
  storage account is assumed to exist.

## Layout

```
infra/terraform/
├── terraform.tf        # provider requirements + azurerm backend (partial config)
├── providers.tf        # fabric + azuread providers (auth from environment)
├── main.tf             # capacity data source + per-database module (for_each over databases)
├── variables.tf
├── outputs.tf
├── environments/
│   ├── <env>.tfvars.example       # committed template — copy to <env>.tfvars (git-ignored)
│   └── <env>.backend.hcl.example  # committed template — copy to <env>.backend.hcl (git-ignored)
└── modules/
    └── fabric-sql-environment/   # one workspace + SQL database + reader group + role assignments
```

The root `for_each`es the module over the `databases` map, so each database is its own
workspace. The `environment` label is any lowercase name — `dev`, `test`, `prod`, `staging` —
a free-form string that names the state file and is baked into workspace and group names.

## Prerequisites

Terraform cannot bootstrap these; the first `apply` fails without them.

1. **Fabric API tenant setting.** In the Fabric Admin portal, enable *Service principals can
   use Fabric APIs* and add the deployment identity to an allowed security group
   ([authentication docs](https://learn.microsoft.com/fabric/database/sql/authentication)).
2. **Workspace creation right** for the identity (same admin surface).
3. **Capacity Contributor** on the existing capacity, so the identity can create workspaces
   and assign them. Paid F/P-SKU capacities support this for a service principal; a **trial**
   capacity does not — see [provisioning.md](../../docs/provisioning.md#identity-setup) for
   the local-provisioning fallback. Reference the capacity with exactly one of two variables:
   `capacity_name` (the normal path — a lookup that also validates the capacity is Active) or
   `capacity_id` with `skip_capacity_state_validation = true` (for capacities the identity
   can't enumerate by name, e.g. a trial; skipping is what turns the Active check off).
4. **Directory write for the reader group** — the Microsoft Graph **`Group.Create`**
   application permission (or the Groups Administrator role). More than the read-only
   directory access the rest of the run needs, so it is easy to miss.

Also assumed: **Storage Blob Data Contributor** on the remote-state container. Verify the
prerequisites by running `terraform plan` on dev as the identity before a real apply.

## Authentication

No secrets are stored. The providers and the state backend authenticate with Microsoft Entra —
GitHub OIDC in CI, your Azure CLI login locally.

**Local:**

```sh
az login   # as the deployment identity, or a user with the prerequisites above
export FABRIC_USE_CLI=true
```

**CI (GitHub Actions):** the workflow needs `permissions: id-token: write` and these
environment variables. The `fabric` and `azuread` providers and the state backend all
authenticate directly from the OIDC token via `*_USE_OIDC` — no `azure/login` / `az` CLI step
is required for provisioning (the deploy workflow uses `azure/login` separately, because
SqlPackage needs an `az`-issued access token):

| Variable | Value |
|---|---|
| `FABRIC_USE_OIDC` | `true` |
| `FABRIC_CLIENT_ID` | the managed identity's **client** ID |
| `FABRIC_TENANT_ID` | your tenant ID |
| `ARM_USE_OIDC` | `true` |
| `ARM_CLIENT_ID` | the managed identity's **client** ID |
| `ARM_TENANT_ID` | your tenant ID |

`FABRIC_*` authenticates the `fabric` provider; `ARM_*` authenticates **both** the state
backend **and** the `azuread` provider — Terraform itself reads no `AZURE_*`/`AAD_*` variables.
(The `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` repository variables you'll see in the deploy
workflows feed `azure/login`, not these providers.)

> **Client ID vs principal ID.** The `*_CLIENT_ID` values are the identity's *client
> (application)* ID. The `principal_id` in `additional_role_assignments` is the Entra *object
> (principal)* ID. Don't mix them up.

## Usage

Copy the templates for your environment and fill them in (the real files are git-ignored):

```sh
cd infra/terraform
cp environments/dev.tfvars.example      environments/dev.tfvars
cp environments/dev.backend.hcl.example environments/dev.backend.hcl
# edit both with your identifiers
```

Then, per environment:

```sh
terraform init -reconfigure -backend-config=environments/dev.backend.hcl
terraform plan  -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars
```

Each environment is a separate state file in the same container; `init -reconfigure` switches
between them. Static checks (no cloud): `terraform fmt -check -recursive` and
`terraform init -backend=false && terraform validate`.

## Outputs

Keyed by the `databases` map key:

- `databases` — per database: `workspace_id`, `sql_database_name`, `sql_server_fqdn`,
  `reader_group_object_id`, `reader_group_display_name`.
- `sql_connection_strings` — per database (sensitive).
- `environment` — the environment label.

```sh
terraform output -json databases | jq '.AppDb.sql_server_fqdn'
```

Nothing is copied anywhere: the deploy workflow reads these outputs from state at run time —
the publish target from `sql_server_fqdn`/`sql_database_name`, the reader-group values as
SQLCMD variables for the post-deployment script ([ci-cd.md](../../docs/ci-cd.md)).

## The reader group

Terraform owns one step of the scoped-read pattern: it creates the per-environment Entra group
and outputs its identifiers. The contained SQL user is created by the post-deployment script
at deploy time, and the connect-granting item **Read** share is a manual portal step — an item
permission, not a workspace role, so it is not expressible in `additional_role_assignments`.
The model is [security.md](../../docs/security.md); the share steps are
[provisioning.md](../../docs/provisioning.md#what-terraform-cannot-reach).

## Multiple databases

Workspace-per-database: each `databases` entry gets its own workspace (`<name> [<env>]`)
holding one SQL database and its reader group. A database entry lines up with the rest of the
repo:

```
databases = { AppDb = {}, ReportingDb = {} }   # infra/terraform/environments/<env>.tfvars
        │
        ├── databases/AppDb/          ── SQL project, built + published by the pipeline
        └── databases/ReportingDb/    ── its own project, its own artifact
                │
        .github/workflows/            ── deploy job keyed off the changed path (databases/<name>/**)
```

**Adding a database is one map entry** (in every environment's tfvars, kept identical) **plus a
`databases/<name>/` SQL project** — the path-filtered deploy picks it up; no new module or
wiring. Per-database fields (`collation`, `backup_retention_days`,
`additional_role_assignments`, `display_name`, `workspace_display_name`,
`reader_group_display_name`, `enable_workspace_identity`) are optional and fall back to the
environment defaults.

## What this does and doesn't do

- Creates each workspace **and an empty SQL database**. Schema is deployed by the pipeline,
  not Terraform — Terraform owns the item's existence, the pipeline owns its contents.
  `collation` is set here because it cannot change after creation; any change to the database
  `configuration` recreates the database.
- Creates the **reader group** and outputs its ids; it does **not** create the reader's SQL
  user or the item-level share ([above](#the-reader-group)).
- The identity that creates a workspace is granted **Admin automatically** —
  `additional_role_assignments` is for *other* principals; listing the deploy identity there
  collides with its implicit grant.
- `workspace_operators` grants the same principals (typically one team security group) a role
  on **every** workspace in the environment — essential on the CI path, where the deploy
  identity would otherwise be each workspace's only principal. Per-database one-offs stay in
  `additional_role_assignments`; operator keys are namespaced (`operator-<key>`) so the two
  never collide.
- Keep the `databases` map **identical across environments**. Per-environment differences
  belong in defaults or per-database overrides, not in which databases exist.

## Committing real values

`*.tfvars` and `*.backend.hcl` hold identifiers (subscription, tenant, capacity, principal
IDs) — not secrets, but not for a public repo. `.gitignore` excludes both; only the
`*.example` templates are committed. `.gitignore` also excludes state, plans, and the provider
cache. The dependency lock file (`.terraform.lock.hcl`) is **not** ignored — commit it so
provider versions stay reproducible.
