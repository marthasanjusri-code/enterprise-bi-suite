/*
  09_dim_customer.sql
  dw.dim_customer: one row per source customer, plus special rows.
    Individuals are labelled "Individual " + account number: no personal names (D65).
    Stores are labelled by store name, plus the account number when two or more stores
    share that name. has_orders marks customers with at least one order; the store-only
    rows that never order stay in the table but can be hidden from slicers.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key customer_key (identity); special rows -1 Unknown.
    - Business key customer_id, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_customer') IS NULL
CREATE TABLE dw.dim_customer (
    customer_key             int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_customer PRIMARY KEY,
    customer_id              int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    account_number           varchar(10) NOT NULL,
    customer_type            varchar(10) NOT NULL,
    store_id                 int NULL,
    store_name               nvarchar(50) NULL,
    customer_label           nvarchar(80) NOT NULL,
    has_orders               bit NOT NULL,
    home_territory           nvarchar(50) NOT NULL,
    home_region_group        nvarchar(50) NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_customer_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_customer_customer_id' AND object_id = OBJECT_ID('dw.dim_customer'))
    CREATE UNIQUE INDEX ux_dim_customer_customer_id ON dw.dim_customer (customer_id) WHERE customer_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_customer
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_customer', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_customer ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_customer WHERE customer_key = -1)
            INSERT INTO dw.dim_customer (customer_key, customer_id, row_type, is_in_source, account_number, customer_type,
                             store_id, store_name, customer_label, has_orders, home_territory, home_region_group,
                             inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, 'Unknown', 'Unknown', NULL, N'Unknown', N'Unknown', 0,
                    N'Unknown', N'Unknown', @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_customer OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  c.CustomerID                                          AS customer_id,
                    'Source'                                              AS row_type,
                    c.AccountNumber                                       AS account_number,
                    CASE WHEN c.StoreID IS NULL THEN 'Individual' ELSE 'Store' END AS customer_type,
                    c.StoreID                                             AS store_id,
                    s.[Name]                                              AS store_name,
                    CAST(CASE WHEN c.StoreID IS NULL THEN N'Individual ' + c.AccountNumber
                              WHEN sn.stores_with_name > 1 THEN s.[Name] + N' (' + c.AccountNumber + N')'
                              ELSE s.[Name] END AS nvarchar(80))          AS customer_label,
                    CAST(CASE WHEN o.CustomerID IS NULL THEN 0 ELSE 1 END AS bit) AS has_orders,
                    ISNULL(t.[Name],  N'Unknown')                         AS home_territory,
                    ISNULL(t.[Group], N'Unknown')                         AS home_region_group
            FROM stg.aw_customer c
            LEFT JOIN stg.aw_store s           ON s.BusinessEntityID = c.StoreID
            LEFT JOIN (SELECT [Name], COUNT(*) AS stores_with_name
                       FROM stg.aw_store GROUP BY [Name]) sn ON sn.[Name] = s.[Name]
            LEFT JOIN (SELECT DISTINCT CustomerID
                       FROM stg.aw_sales_order_header) o ON o.CustomerID = c.CustomerID
            LEFT JOIN stg.aw_sales_territory t ON t.TerritoryID = c.TerritoryID
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            account_number = s.account_number,
            customer_type = s.customer_type,
            store_id = s.store_id,
            store_name = s.store_name,
            customer_label = s.customer_label,
            has_orders = s.has_orders,
            home_territory = s.home_territory,
            home_region_group = s.home_region_group,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_customer d
        JOIN #src s ON s.customer_id = d.customer_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.account_number, s.customer_type, s.store_id, s.store_name,
                   s.customer_label, s.has_orders, s.home_territory, s.home_region_group, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.account_number, d.customer_type, d.store_id, d.store_name,
                   d.customer_label, d.has_orders, d.home_territory, d.home_region_group, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_customer (
            customer_id, row_type, is_in_source, account_number, customer_type, store_id,
            store_name, customer_label, has_orders, home_territory, home_region_group,
            inserted_batch_id, updated_batch_id)
        SELECT
            s.customer_id, s.row_type, 1, s.account_number, s.customer_type, s.store_id,
            s.store_name, s.customer_label, s.has_orders, s.home_territory, s.home_region_group,
            @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer d WHERE d.customer_id = s.customer_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_customer d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.customer_id = d.customer_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_customer'))
            SET IDENTITY_INSERT dw.dim_customer OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
