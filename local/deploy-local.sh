#!/usr/bin/env bash
# Build a database's dacpac and publish it to the local SQL Server container so you can poke
# around with a client tool. This is SQL Server, NOT Fabric — see README.md for the caveat.
#
# Usage (from anywhere):  local/deploy-local.sh [database]
#   [database] names a databases/<database>/ project folder (default AppDb); the dacpac is published
#   into a container database of the same name.
# Prereqs: Docker, the .NET SDK, and SqlPackage on PATH
#          (dotnet tool install -g microsoft.sqlpackage).
set -euo pipefail

db="${1:-AppDb}"
sa_password="${MSSQL_SA_PASSWORD:-Local_Dev_Passw0rd!}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
project="$repo_root/databases/$db/$db.sqlproj"
dacpac="$repo_root/databases/$db/bin/Release/$db.dacpac"

if [ ! -f "$project" ]; then
  echo "No SQL project at databases/$db/$db.sqlproj — pass a database folder name from databases/." >&2
  exit 1
fi

echo "==> Starting SQL Server (waiting until it accepts connections)..."
MSSQL_SA_PASSWORD="$sa_password" docker compose -f "$script_dir/docker-compose.yml" up -d --wait

echo "==> Building $db (Release)..."
dotnet build "$project" -c Release -v minimal

echo "==> Publishing to localhost,1433 / $db ..."
conn="Server=localhost,1433;Database=$db;User ID=sa;Password=$sa_password;TrustServerCertificate=True;Encrypt=True"

# On Git Bash / MSYS (Windows), SqlPackage needs a native Windows path AND MSYS must not
# rewrite its /Option: arguments into paths (it turns /SourceFile: into a filesystem path and
# strips the leading slash off /p: and /v:). Convert the path and disable that rewriting here;
# on Linux/macOS this branch is skipped and the arguments pass through unchanged.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    dacpac="$(cygpath -w "$dacpac")"
    export MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1
    ;;
esac

# AllowIncompatiblePlatform: the dacpac targets Fabric, the container is SQL Server. The
# reader-group SQLCMD variables get non-GUID placeholders, so the Entra reader-group block in
# the post-deploy script no-ops (it runs only for a real group object id).
sqlpackage /Action:Publish \
  /SourceFile:"$dacpac" \
  /TargetConnectionString:"$conn" \
  /p:AllowIncompatiblePlatform=true \
  /v:ReaderGroupName=none \
  /v:ReaderGroupObjectId=none

echo "==> Done. Connect a client to  localhost,1433  (user 'sa', the password above), database '$db'."
echo "    When you're finished probing, shut it down:"
echo "      docker compose -f local/docker-compose.yml down -v   # remove the container and delete its data volume"
