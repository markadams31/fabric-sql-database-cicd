CREATE TABLE [app].[Customer]
(
    [CustomerId] INT NOT NULL IDENTITY (1, 1),
    [Name] NVARCHAR(200) NOT NULL,
    [Email] NVARCHAR(256) NULL,
    -- Audit columns are owned by [app].[trg_Customer_Audit], never written by the client, so
    -- they are nullable: an AFTER trigger stamps them just after the row is written.
    [CreatedAt] DATETIME2(7) NULL,
    [CreatedBy] NVARCHAR(128) NULL,
    [ModifiedAt] DATETIME2(7) NULL,
    [ModifiedBy] NVARCHAR(128) NULL,
    CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([CustomerId] ASC)
);
GO
-- Email is a business identifier when present; a filtered unique index enforces
-- one-account-per-address while still allowing rows that have no email.
CREATE UNIQUE NONCLUSTERED INDEX [UX_Customer_Email]
    ON [app].[Customer] ([Email] ASC)
    WHERE [Email] IS NOT NULL;
