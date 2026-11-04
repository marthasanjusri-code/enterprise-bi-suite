/*
  10_dim_promotion.sql
  dw.dim_promotion: one row per source promotion, plus special rows.
    Offer 1 "No Discount" is a real promotion, so no Not-applicable row is needed (D66).
    was_used marks offers that appear on at least one sales line.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key promotion_key (identity); special rows -1 Unknown.
    - Business key promotion_id, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_promotion') IS NULL
CREATE TABLE dw.dim_promotion (
    promotion_key            int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_promotion PRIMARY KEY,
    promotion_id             int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    promotion_name           nvarchar(255) NOT NULL,
    promotion_type           nvarchar(50) NOT NULL,
    promotion_category       nvarchar(50) NOT NULL,
    offer_discount_pct       smallmoney NULL,
    start_date               date NULL,
    end_date                 date NULL,
    was_used                 bit NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_promotion_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_promotion_promotion_id' AND object_id = OBJECT_ID('dw.dim_promotion'))
    CREATE UNIQUE INDEX ux_dim_promotion_promotion_id ON dw.dim_promotion (promotion_id) WHERE promotion_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_promotion
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_promotion', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_promotion ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_promotion WHERE promotion_key = -1)
            INSERT INTO dw.dim_promotion (promotion_key, promotion_id, row_type, is_in_source, promotion_name, promotion_type,
                             promotion_category, offer_discount_pct, start_date, end_date, was_used,
                             inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', N'Unknown', N'Unknown', NULL, NULL, NULL, 0,
                    @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_promotion OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  o.SpecialOfferID                AS promotion_id,
                    'Source'                        AS row_type,
                    o.[Description]                 AS promotion_name,
                    o.[Type]                        AS promotion_type,
                    o.Category                      AS promotion_category,
                    o.DiscountPct                   AS offer_discount_pct,
                    CAST(o.StartDate AS date)       AS start_date,
                    CAST(o.EndDate AS date)         AS end_date,
                    CAST(CASE WHEN u.SpecialOfferID IS NULL THEN 0 ELSE 1 END AS bit) AS was_used
            FROM stg.aw_special_offer o
            LEFT JOIN (SELECT DISTINCT SpecialOfferID
                       FROM stg.aw_sales_order_detail) u ON u.SpecialOfferID = o.SpecialOfferID
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            promotion_name = s.promotion_name,
            promotion_type = s.promotion_type,
            promotion_category = s.promotion_category,
            offer_discount_pct = s.offer_discount_pct,
            start_date = s.start_date,
            end_date = s.end_date,
            was_used = s.was_used,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_promotion d
        JOIN #src s ON s.promotion_id = d.promotion_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.promotion_name, s.promotion_type, s.promotion_category,
                   s.offer_discount_pct, s.start_date, s.end_date, s.was_used, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.promotion_name, d.promotion_type, d.promotion_category,
                   d.offer_discount_pct, d.start_date, d.end_date, d.was_used, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_promotion (
            promotion_id, row_type, is_in_source, promotion_name, promotion_type,
            promotion_category, offer_discount_pct, start_date, end_date, was_used,
            inserted_batch_id, updated_batch_id)
        SELECT
            s.promotion_id, s.row_type, 1, s.promotion_name, s.promotion_type, s.promotion_category,
            s.offer_discount_pct, s.start_date, s.end_date, s.was_used, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_promotion d WHERE d.promotion_id = s.promotion_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_promotion d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.promotion_id = d.promotion_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_promotion'))
            SET IDENTITY_INSERT dw.dim_promotion OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
