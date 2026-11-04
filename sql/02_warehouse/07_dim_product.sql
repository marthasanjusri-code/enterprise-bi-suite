/*
  07_dim_product.sql
  dw.dim_product: one row per source product, plus special rows.
    Internal parts (no subcategory) get category and subcategory "Internal parts" (D60).
    Codes shown as words from the source descriptions: product line R Road, M Mountain,
    T Touring, S Standard; class H High, M Medium, L Low; style W Women's, M Men's, U Universal.
    Missing text is "N/A". Standard cost and list price of 0 are stored as NULL (D17, D60).
    Status is Discontinued when the product has a sell end date.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key product_key (identity); special rows -1 Unknown.
    - Business key product_id, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_product') IS NULL
CREATE TABLE dw.dim_product (
    product_key              int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_product PRIMARY KEY,
    product_id               int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    product_number           nvarchar(25) NOT NULL,
    product_name             nvarchar(50) NOT NULL,
    color                    nvarchar(15) NOT NULL,
    size                     nvarchar(5) NOT NULL,
    product_line             varchar(10) NOT NULL,
    class                    varchar(10) NOT NULL,
    style                    varchar(10) NOT NULL,
    subcategory              nvarchar(50) NOT NULL,
    category                 nvarchar(50) NOT NULL,
    is_finished_good         bit NOT NULL,
    is_made_in_house         bit NOT NULL,
    safety_stock_level       smallint NULL,
    reorder_point            smallint NULL,
    standard_cost            money NULL,
    list_price               money NULL,
    sell_start_date          date NULL,
    sell_end_date            date NULL,
    product_status           varchar(12) NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_product_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_product_product_id' AND object_id = OBJECT_ID('dw.dim_product'))
    CREATE UNIQUE INDEX ux_dim_product_product_id ON dw.dim_product (product_id) WHERE product_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_product
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_product', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_product ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_product WHERE product_key = -1)
            INSERT INTO dw.dim_product (product_key, product_id, row_type, is_in_source, product_number, product_name, color,
                             size, product_line, class, style, subcategory, category, is_finished_good,
                             is_made_in_house, safety_stock_level, reorder_point, standard_cost, list_price,
                             sell_start_date, sell_end_date, product_status, inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', N'Unknown', N'Unknown', N'N/A', 'Unknown',
                    'Unknown', 'Unknown', N'Unknown', N'Unknown', 0, 0, NULL, NULL, NULL, NULL, NULL, NULL,
                    'Unknown', @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_product OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  p.ProductID                                                AS product_id,
                    'Source'                                                   AS row_type,
                    p.ProductNumber                                            AS product_number,
                    p.[Name]                                                   AS product_name,
                    ISNULL(p.Color, N'N/A')                                    AS color,
                    ISNULL(p.Size, N'N/A')                                     AS size,
                    CASE RTRIM(p.ProductLine) WHEN 'R' THEN 'Road' WHEN 'M' THEN 'Mountain'
                         WHEN 'T' THEN 'Touring' WHEN 'S' THEN 'Standard' ELSE 'N/A' END AS product_line,
                    CASE RTRIM(p.Class) WHEN 'H' THEN 'High' WHEN 'M' THEN 'Medium'
                         WHEN 'L' THEN 'Low' ELSE 'N/A' END                    AS class,
                    CASE RTRIM(p.Style) WHEN 'W' THEN 'Women''s' WHEN 'M' THEN 'Men''s'
                         WHEN 'U' THEN 'Universal' ELSE 'N/A' END              AS style,
                    ISNULL(sc.[Name], N'Internal parts')                       AS subcategory,
                    ISNULL(c.[Name],  N'Internal parts')                       AS category,
                    p.FinishedGoodsFlag                                        AS is_finished_good,
                    p.MakeFlag                                                 AS is_made_in_house,
                    p.SafetyStockLevel                                         AS safety_stock_level,
                    p.ReorderPoint                                             AS reorder_point,
                    NULLIF(p.StandardCost, 0)                                  AS standard_cost,
                    NULLIF(p.ListPrice, 0)                                     AS list_price,
                    CAST(p.SellStartDate AS date)                              AS sell_start_date,
                    CAST(p.SellEndDate AS date)                                AS sell_end_date,
                    CASE WHEN p.SellEndDate IS NULL THEN 'Active' ELSE 'Discontinued' END AS product_status
            FROM stg.aw_product p
            LEFT JOIN stg.aw_product_subcategory sc ON sc.ProductSubcategoryID = p.ProductSubcategoryID
            LEFT JOIN stg.aw_product_category c     ON c.ProductCategoryID     = sc.ProductCategoryID
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            product_number = s.product_number,
            product_name = s.product_name,
            color = s.color,
            size = s.size,
            product_line = s.product_line,
            class = s.class,
            style = s.style,
            subcategory = s.subcategory,
            category = s.category,
            is_finished_good = s.is_finished_good,
            is_made_in_house = s.is_made_in_house,
            safety_stock_level = s.safety_stock_level,
            reorder_point = s.reorder_point,
            standard_cost = s.standard_cost,
            list_price = s.list_price,
            sell_start_date = s.sell_start_date,
            sell_end_date = s.sell_end_date,
            product_status = s.product_status,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_product d
        JOIN #src s ON s.product_id = d.product_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.product_number, s.product_name, s.color, s.size, s.product_line, s.class,
                   s.style, s.subcategory, s.category, s.is_finished_good, s.is_made_in_house,
                   s.safety_stock_level, s.reorder_point, s.standard_cost, s.list_price, s.sell_start_date,
                   s.sell_end_date, s.product_status, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.product_number, d.product_name, d.color, d.size, d.product_line, d.class,
                   d.style, d.subcategory, d.category, d.is_finished_good, d.is_made_in_house,
                   d.safety_stock_level, d.reorder_point, d.standard_cost, d.list_price, d.sell_start_date,
                   d.sell_end_date, d.product_status, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_product (
            product_id, row_type, is_in_source, product_number, product_name, color, size,
            product_line, class, style, subcategory, category, is_finished_good, is_made_in_house,
            safety_stock_level, reorder_point, standard_cost, list_price, sell_start_date,
            sell_end_date, product_status, inserted_batch_id, updated_batch_id)
        SELECT
            s.product_id, s.row_type, 1, s.product_number, s.product_name, s.color, s.size,
            s.product_line, s.class, s.style, s.subcategory, s.category, s.is_finished_good,
            s.is_made_in_house, s.safety_stock_level, s.reorder_point, s.standard_cost,
            s.list_price, s.sell_start_date, s.sell_end_date, s.product_status, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_product d WHERE d.product_id = s.product_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_product d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.product_id = d.product_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_product'))
            SET IDENTITY_INSERT dw.dim_product OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
