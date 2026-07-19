# Local runtime testing (SQL Server in Docker)

Deploy the built dacpac to a throwaway SQL Server container and explore it with any client
tool — the **runtime truth** the offline build can't give: triggers fire, `CHECK` constraints
reject bad data, the post-deployment script runs. It is optional and additive; the gate that
blocks a merge is still the offline pair (`dotnet build build.proj` +
`sqlfluff lint databases`). Where this tier sits among build / container / workspace is
[docs/local-development.md](../docs/local-development.md#three-tiers-of-truth).

## This is SQL Server, not Fabric

The container is `mcr.microsoft.com/mssql/server` — the same engine family as Fabric SQL, so it
gives **T-SQL behavior** (schema, triggers, constraints, post-deploy) but not Fabric's
Entra-only auth, contained-user access model, or platform limits. Two consequences:

- The publish passes **`/p:AllowIncompatiblePlatform=true`**, because the dacpac targets Fabric
  and the container is SQL Server.
- The Entra reader-group provisioning in the post-deploy script is **skipped automatically** —
  its reader-group SQLCMD variables get a non-GUID placeholder (`none`), and the guard runs only
  for a valid GUID object id, so it no-ops.

## Prerequisites

- Docker (Docker Desktop / Engine with Compose v2)
- The .NET SDK and SqlPackage (`dotnet tool install -g microsoft.sqlpackage`)

## Use it

```sh
# Build + publish (starts the container and waits, builds Release, publishes).
local/deploy-local.sh                 # optional arg: a databases/<name> folder (default AppDb)

# Connect a client to  localhost,1433  ·  user 'sa'  ·  the SA password
# (SSMS, Azure Data Studio, the VS Code mssql extension, DBeaver, ...).

# Iterate: edit SQL, re-run deploy-local.sh to re-publish.

# Tear down (-v also deletes the data volume).
docker compose -f local/docker-compose.yml down -v
```

The SA password defaults to a local-only throwaway; override it by exporting
`MSSQL_SA_PASSWORD` before running (it must meet SQL Server's complexity rules).

**Not using bash?** `deploy-local.sh` is a convenience wrapper. After
`docker compose -f local/docker-compose.yml up -d --wait` and
`dotnet build databases/AppDb/AppDb.sqlproj -c Release`, the publish is one command that runs
in any shell:

```sh
sqlpackage /Action:Publish /SourceFile:databases/AppDb/bin/Release/AppDb.dacpac /TargetConnectionString:"Server=localhost,1433;Database=AppDb;User ID=sa;Password=Local_Dev_Passw0rd!;TrustServerCertificate=True;Encrypt=True" /p:AllowIncompatiblePlatform=true /v:ReaderGroupName=none /v:ReaderGroupObjectId=none
```

On Apple Silicon the SQL Server image runs under amd64 emulation — slower, but it works.
