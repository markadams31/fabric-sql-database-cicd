CREATE TRIGGER [app].[trg_Order_Audit]
ON [app].[Order]
AFTER INSERT, UPDATE
AS
BEGIN
    -- Same audit pattern as [app].[trg_Customer_Audit]: on INSERT stamp all four columns, on
    -- UPDATE refresh Modified* only. See that trigger for the full rationale.
    SET NOCOUNT ON;

    DECLARE @now DATETIME2(7) = SYSUTCDATETIME();
    DECLARE @who NVARCHAR(128) = ORIGINAL_LOGIN();

    IF NOT EXISTS (SELECT 1 FROM deleted)
        UPDATE o
        SET
            o.[CreatedAt] = @now,
            o.[CreatedBy] = @who,
            o.[ModifiedAt] = @now,
            o.[ModifiedBy] = @who
        FROM [app].[Order] AS o
        INNER JOIN inserted AS i ON o.[OrderId] = i.[OrderId];
    ELSE
        UPDATE o
        SET
            o.[ModifiedAt] = @now,
            o.[ModifiedBy] = @who
        FROM [app].[Order] AS o
        INNER JOIN inserted AS i ON o.[OrderId] = i.[OrderId];
END;
