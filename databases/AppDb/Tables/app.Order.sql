CREATE TABLE [app].[Order]
(
    [OrderId] INT NOT NULL IDENTITY (1, 1),
    [CustomerId] INT NOT NULL,
    [OrderedAt] DATETIME2(3) NOT NULL CONSTRAINT [DF_Order_OrderedAt] DEFAULT (SYSUTCDATETIME()),
    [TotalAmount] DECIMAL(19, 4) NOT NULL CONSTRAINT [DF_Order_TotalAmount] DEFAULT (0),
    [Status] NVARCHAR(20) NOT NULL CONSTRAINT [DF_Order_Status] DEFAULT (N'Pending'),
    -- Audit columns are owned by [app].[trg_Order_Audit] (nullable; stamped just after write).
    [CreatedAt] DATETIME2(7) NULL,
    [CreatedBy] NVARCHAR(128) NULL,
    [ModifiedAt] DATETIME2(7) NULL,
    [ModifiedBy] NVARCHAR(128) NULL,
    CONSTRAINT [PK_Order] PRIMARY KEY CLUSTERED ([OrderId] ASC),
    CONSTRAINT [FK_Order_Customer] FOREIGN KEY ([CustomerId]) REFERENCES [app].[Customer] ([CustomerId]),
    CONSTRAINT [CK_Order_Status] CHECK ([Status] IN (N'Pending', N'Paid', N'Shipped', N'Cancelled'))
);
GO
-- Foreign-key columns are indexed (convention-checked).
CREATE NONCLUSTERED INDEX [IX_Order_CustomerId]
    ON [app].[Order] ([CustomerId] ASC);
