# Local Development

The inner loop: how to know a schema change is good without touching Fabric. The answer is two
standard commands, run for you by git hooks — no bespoke scripts, no local emulator required.

## Tool setup

```sh
# T-SQL linting: SQLFluff pinned to the CI version + this repo's custom rule plugin.
pip install sqlfluff==4.2.2 -e ./analyzers/sqlfluff-fabric-rules

# The git-hook framework that runs the checks automatically
pip install pre-commit
pre-commit install               # lint on commit
pre-commit install -t pre-push   # build on push
```

You also need the **.NET SDK** (`dotnet build` compiles the SQL project and runs analysis).
**Azure CLI** is only for connecting to a dev workspace ([below](#connecting-to-a-dev-workspace)),
**Terraform** only for provisioning ([provisioning.md](provisioning.md)), **Docker** only for
the optional runtime tier. The hook definitions are in
[.pre-commit-config.yaml](../.pre-commit-config.yaml) — the source of truth for what runs when.

## The loop

Edit a `.sql` file under `databases/<name>/`; two commands validate it:

```sh
sqlfluff lint databases   # style
dotnet build build.proj   # schema validation + conventions
```

You rarely type them — the hooks run the lint on every commit and the build on every push, so
a broken change stops at your machine. Run either by hand for a faster answer on one file. This
is exactly what CI runs on your PR ([ci-cd.md](ci-cd.md)): same two commands, same config, so a
green loop locally means a green check on the PR.

**`sqlfluff lint`** checks the style of the T-SQL *source text* — casing, layout, line length —
against [.sqlfluff](../.sqlfluff), plus this repo's custom source-text rule in
[analyzers/sqlfluff-fabric-rules](../analyzers/sqlfluff-fabric-rules) (the shipped example
flags non-Unicode literals: `'x'` where `N'x'` was meant).

**`dotnet build`** does the heavy lifting in one pass: it compiles against the
SQL-database-in-Fabric target (so unsupported T-SQL and anti-patterns like `SELECT *` fail at
*build*, not deploy) and runs the code-analysis rules over the compiled model — an error-level
rule fails the build, a warning surfaces without blocking. Which rules run and at what severity
is [conventions.md](conventions.md)'s territory; "does it build" is the whole gate.

A database is a `databases/<name>/` folder with a minimal `.sqlproj` — target platform and rule
set are inherited from `databases/Directory.Build.props`, and the build discovers every project
by glob, so a database you add is linted and rule-checked with no extra wiring.

## Three tiers of truth

There is no local Fabric emulator, and none is needed: each question has the cheapest place
that can answer it honestly.

| Tier | Answers | Fidelity |
|---|---|---|
| **`dotnet build`** (offline) | *Structural* — is the schema valid for Fabric, do conventions pass? | Full, for structure. The whole gate. |
| **`local/` container** (optional) | *Behavioral* — does this trigger fire, does this constraint reject the row? | Engine truth, **not** Fabric truth. |
| **Dev Fabric workspace** | *Platform* — auth, serverless resume, does a publish actually land? | Fabric truth. |

Work down the ladder only as far as the question requires. The build answers most changes; the
container and the workspace are for the ones it structurally can't.

## The local runtime tier

[local/](../local/) runs a SQL Server container: it starts the engine, deploys the **built
dacpac** with SqlPackage (using `AllowIncompatiblePlatform`, since the dacpac targets Fabric
and the container is SQL Server), and lets you connect with any client and poke around. Start
it via [local/README.md](../local/README.md). Keep straight:

- **It is SQL Server, not Fabric** — engine truth for T-SQL behavior, but not Fabric
  authentication, capacity behavior, or platform quirks. For those, use a dev workspace.
- **It is additive, never the gate.** The two commands above are the whole offline gate;
  nothing about the build or the hooks depends on the container. Reach for it when a change is
  behaviorally suspicious, not on every edit.
- **Reader-group provisioning no-ops here.** The post-deployment script that provisions the
  scoped reader is driven by an Entra group object id from Terraform; there is no Entra
  directory behind a local container, so that step does nothing — expected, since the tier is
  for engine behavior, not the access model.

## Connecting to a dev workspace

A real SQL database in a dev Fabric workspace is where you go for **Fabric truth**:
authentication behavior, serverless resume, and confirming a publish lands (a cold first
connection is the database resuming, not a fault). Connect SSMS or the VS Code mssql extension
to the database's connection string (from its page in the Fabric portal) using your Entra
identity ([connect docs](https://learn.microsoft.com/fabric/database/sql/connect)) — auth is
Entra-only, there are no SQL logins to fall back on. Your account needs access to the database,
granted by the workspace role assignments in [provisioning.md](provisioning.md).
