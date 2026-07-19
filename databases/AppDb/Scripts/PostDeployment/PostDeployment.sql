/*
    Post-deployment script for AppDb.

    Runs on EVERY publish, so every statement must be idempotent and state-guarded — check
    the live state, then apply only if it differs. Never issue unconditional changes.
    See ../../../../docs/conventions.md for the required pattern and an example.

    Use this for database-scoped settings that schema deployment doesn't carry, and for
    seeding small reference/lookup data with guarded MERGE statements.
*/

-- Read-only access group. Create the contained database user for the Entra reader security
-- group and add it to the [app_reader] role (SELECT on the app schema). The group and its
-- object id come from Terraform; the deploy pipeline passes them as the SQLCMD variables
-- below. The user is created BY OBJECT ID (WITH SID = ..., TYPE = X) because a service-principal
-- deploy identity can't use FROM EXTERNAL PROVIDER in Fabric. The statements are built into a
-- variable and run with EXEC (EXEC concatenates only strings/variables, not function calls).
--
-- The block runs only when a valid group object id (a GUID) is supplied. TRY_CONVERT returns
-- NULL for anything that isn't a GUID, so a local build, or a publish that passes a non-GUID
-- placeholder (e.g. the local Docker script), simply no-ops. Idempotent.
DECLARE @objectId UNIQUEIDENTIFIER = TRY_CONVERT(UNIQUEIDENTIFIER, N'$(ReaderGroupObjectId)');

IF @objectId IS NOT NULL AND N'$(ReaderGroupName)' <> N''
BEGIN
    DECLARE @cmd NVARCHAR(MAX);

    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'$(ReaderGroupName)')
    BEGIN
        -- Object id (GUID) -> the binary(16) SID form CREATE USER expects; TYPE = X = group.
        DECLARE @sid NVARCHAR(MAX) = CONVERT(NVARCHAR(MAX), CONVERT(VARBINARY(16), @objectId), 1);
        SET @cmd = N'CREATE USER ' + QUOTENAME(N'$(ReaderGroupName)') + N' WITH SID = ' + @sid + N', TYPE = X;';
        EXEC (@cmd);
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.database_role_members AS drm
        INNER JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
        INNER JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id
        WHERE r.[name] = N'app_reader' AND m.[name] = N'$(ReaderGroupName)'
    )
    BEGIN
        SET @cmd = N'ALTER ROLE [app_reader] ADD MEMBER ' + QUOTENAME(N'$(ReaderGroupName)') + N';';
        EXEC (@cmd);
    END;
END;
