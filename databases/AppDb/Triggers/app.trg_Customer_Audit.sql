CREATE TRIGGER [app].[trg_Customer_Audit]
ON [app].[Customer]
AFTER INSERT, UPDATE
AS
BEGIN
    -- The audit columns are owned here, not by the client. SET NOCOUNT ON keeps the trigger's
    -- UPDATE off the client's rowcount. On INSERT (no rows in `deleted`) all four columns are
    -- stamped; on UPDATE only Modified* is refreshed. ORIGINAL_LOGIN() records the identity
    -- that connected (unchanged by EXECUTE AS); for a service principal it resolves to the
    -- app's object-id GUID. Relies on RECURSIVE_TRIGGERS being OFF (the default) so the
    -- trigger's own UPDATE does not re-fire it.
    SET NOCOUNT ON;

    DECLARE @now DATETIME2(7) = SYSUTCDATETIME();
    DECLARE @who NVARCHAR(128) = ORIGINAL_LOGIN();

    IF NOT EXISTS (SELECT 1 FROM deleted)
        UPDATE c
        SET
            c.[CreatedAt] = @now,
            c.[CreatedBy] = @who,
            c.[ModifiedAt] = @now,
            c.[ModifiedBy] = @who
        FROM [app].[Customer] AS c
        INNER JOIN inserted AS i ON c.[CustomerId] = i.[CustomerId];
    ELSE
        UPDATE c
        SET
            c.[ModifiedAt] = @now,
            c.[ModifiedBy] = @who
        FROM [app].[Customer] AS c
        INNER JOIN inserted AS i ON c.[CustomerId] = i.[CustomerId];
END;
