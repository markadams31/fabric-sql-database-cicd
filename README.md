# Fabric SQL Database CI/CD

A [SQL database in Microsoft Fabric](https://learn.microsoft.com/fabric/database/sql/overview)
takes a few portal clicks to create — and comes with nothing to keep what happens next safe:
schema edited live in the portal, no reviews, no environments, no answer to "what changed,
and who approved it?"

This repo is a **working CI/CD pipeline for those databases** — fork it, connect your tenant,
and your schema becomes versioned code with guardrails. It is built entirely from standard
tools (SQL Database Projects, GitHub Actions, Terraform, SqlPackage); there is no framework
to learn and nothing bespoke to maintain.

Use it as a **starting point** — delete the example database, add your own; the pipeline
carries over — or as a **reference** for the reasoning behind each gate. This page gets you
running; [docs/](docs/) holds the depth.

## How a change ships

1. **You edit `.sql` files** in `databases/<name>/` — plain T-SQL, one file per table,
   trigger, or grant. Nothing is ever hand-applied to a live database.
2. **Git hooks catch mistakes before a PR exists.** Committing lints the T-SQL; pushing
   compiles it against the Fabric platform and runs every code-analysis rule — unsupported
   T-SQL and convention violations fail on your machine, not in review.
3. **The pull request is the gate.** CI runs the same two commands as the hooks, so the merge
   gate and local feedback never diverge. Review reads real T-SQL diffs.
4. **Merge deploys.** CI builds one versioned artifact per changed database and promotes that
   exact artifact dev → test → prod. SqlPackage computes each migration; a change that would
   lose data is blocked unless explicitly signed off, and a database that drifted from the
   repo fails its deploy rather than papering over it.
5. **Production is approved with the facts.** The prod stage pauses for a reviewer who sees
   the exact migration T-SQL and its data-loss consequences, generated against live prod —
   and only that reviewed plan can apply.

The two commands behind steps 2–3, runnable any time:

```sh
dotnet build build.proj   # compile every schema for Fabric + run all analysis rules
sqlfluff lint databases   # check T-SQL source style
```

## The stance behind it

**Everything is code, and the build checks it** — no step in the lifecycle depends on someone
remembering to do it:

- **Schema is code** — a SQL Database Project per database, compiled against the Fabric
  target platform so invalid T-SQL fails at *build*, not at deploy.
- **Conventions are code** — house rules (audit columns, bounded types, no `SELECT *`) run as
  code-analysis rules inside `dotnet build`; anti-patterns fail the build, org conventions
  start as warnings a team escalates as it adopts them ([conventions.md](docs/conventions.md)).
- **Environments are code** — Terraform stands up the workspaces and databases, one workspace
  per database ([provisioning.md](docs/provisioning.md)).
- **Deployment is code** — GitHub Actions owns the whole promotion; the deploy identity is
  the only principal that can write to a database ([ci-cd.md](docs/ci-cd.md)).

Everything downstream — reproducibility, reviewable changes, a single answer to "what's
deployed where" — follows from that one commitment.

## Quickstart

1. **Fork and clone** this repository.

2. **Install the linter and git hooks** (one time):

   ```sh
   pip install sqlfluff==4.2.2 -e ./analyzers/sqlfluff-fabric-rules   # SQLFluff pinned to the CI version + this repo's custom rule
   pip install pre-commit
   pre-commit install               # lint on commit
   pre-commit install -t pre-push   # build on push
   ```

3. **Build and lint** locally:

   ```sh
   dotnet build build.proj
   sqlfluff lint databases
   ```

   A clean build means the schema is valid for the Fabric platform and every error-severity
   rule passed.

4. **Make it yours.** Create your own database under `databases/` with the
   [SQL Database Projects](https://learn.microsoft.com/sql/tools/sql-database-projects/sql-database-projects)
   tooling — the [VS Code MSSQL extension](https://learn.microsoft.com/sql/tools/visual-studio-code-extensions/mssql/mssql-extension-visual-studio-code)
   or `dotnet new sqlproj` — which also gives you table designers, schema compare, and
   **import of an existing database** (*Create Project from Database*) to bring a live schema
   into source control. Slim the generated `.sqlproj` to name-only like
   [`AppDb.sqlproj`](databases/AppDb/AppDb.sqlproj) so it inherits the shared Fabric target
   and rule set, and the repo-wide build discovers it. Keep the bundled `AppDb/` as a working
   reference until yours builds and deploys, then delete it.

5. **Provision environments** (needs a Fabric tenant): the
   [Terraform README](infra/terraform/README.md) has the commands,
   [docs/provisioning.md](docs/provisioning.md) the one-time identity setup.

6. **Open a PR** and watch CI run the same lint and build you just ran.

## Prerequisites

Local tools: **.NET SDK** (build), **Python** (SQLFluff lint), **pre-commit** (git hooks),
and optionally **Docker** (the `local/` SQL Server runtime tier) and **SqlPackage**
(`dotnet tool install -g microsoft.sqlpackage` — only for manual publishes; CI installs its
own pinned copy).

To provision and deploy, the cloud side needs:

- A Fabric tenant with an active **paid capacity** (F/P SKU) and rights to create workspaces.
- The tenant setting **Service principals can use Fabric APIs** enabled.
- Rights to create a **user-assigned managed identity** with **GitHub OIDC federated
  credentials** — no app registration, no stored secrets anywhere.
- Microsoft Graph **`Group.Create`** for the identity, because Terraform creates a
  per-environment reader security group.

The exact commands and the identity model: [docs/provisioning.md](docs/provisioning.md).

## Access model

Access has two layers, and both apply: **Fabric** controls decide who can *connect*
(workspace roles, item permissions); **SQL** controls decide what they can *do* once in
(roles, `GRANT`/`DENY`). The deploy identity is the only writer — humans read, which is what
keeps the repo the single source of truth. The complete model is
[docs/security.md](docs/security.md); break-glass access is in
[docs/operations.md](docs/operations.md).

## Repository layout

```
.
├── build.proj                  # builds every project by glob — a database is just a folder
├── databases/                  # SQL Database Projects — one folder per database
│   ├── Directory.Build.props   #   shared target platform + rule set (change rules here)
│   └── AppDb/                  #   the bundled example — delete and add your own
│       ├── Tables/             #     one file per table
│       ├── Triggers/           #     one file per audit trigger
│       ├── Security/           #     roles and grants
│       └── Scripts/            #     post-deployment + data migrations (not compiled)
├── analyzers/FabricSqlRules/   # custom DacFx code-analysis rules (a C# class library)
├── local/                      # optional Docker SQL Server runtime for local testing
├── infra/terraform/            # Fabric provisioning — one workspace per database
├── .github/workflows/          # PR validation, provisioning, build-once deploy
├── .github/actions/            #   plan-migration: scripts a deploy + data-loss digest
├── .pre-commit-config.yaml     # local git hooks: lint on commit, build on push
├── .sqlfluff                   # SQLFluff style configuration
└── docs/                       # the deep material — see the map below
```

## Add or remove a database

Each database is a SQL Database Project in its own `databases/<name>/` folder, so the estate
grows and shrinks without touching the pipeline:

- **Add one** — create the project with the SQL Database Projects tooling (or import an
  existing database — quickstart step 4), slim the `.sqlproj` to name-only so it inherits the
  shared target platform and rules, and add one entry to the Terraform `databases` map in
  each environment. The build and the deploy discover it automatically.
- **Remove one** — delete the folder and drop its map entry
  ([decommissioning](docs/provisioning.md#decommissioning)).

The contract is documented in the [Terraform README](infra/terraform/README.md#multiple-databases).

## Documentation map

| Read this | To answer |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Why is it built this way? What does Microsoft own, and what do we own? |
| [docs/conventions.md](docs/conventions.md) | What does the build enforce, and how do I add or change a rule? |
| [docs/security.md](docs/security.md) | Who can connect, what can they do, and how is it granted without secrets? |
| [docs/local-development.md](docs/local-development.md) | How do I develop and validate without touching Fabric? |
| [docs/ci-cd.md](docs/ci-cd.md) | What gates a PR, what does a deploy do, and what are the paths back? |
| [docs/data-migrations.md](docs/data-migrations.md) | How do I backfill or migrate data safely? |
| [docs/provisioning.md](docs/provisioning.md) | How do I stand up environments from zero — or add more? |
| [docs/operations.md](docs/operations.md) | How is the database observed and operated day to day? |

## License

[MIT](LICENSE).
