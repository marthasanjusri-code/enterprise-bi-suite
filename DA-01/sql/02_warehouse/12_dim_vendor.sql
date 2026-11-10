/*
  12_dim_vendor.sql
  dw.dim_vendor: one row per source vendor, plus special rows.
    Credit rating as number and as words from the source description:
    1 Superior, 2 Excellent, 3 Above average, 4 Average, 5 Below average.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key vendor_key (identity); special rows -1 Unknown.
    - Business key vendor_id, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_vendor') IS NULL
CREATE TABLE dw.dim_vendor (
    vendor_key               int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_vendor PRIMARY KEY,
    vendor_id                int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    vendor_name              nvarchar(50) NOT NULL,
    credit_rating            tinyint NULL,
    credit_rating_label      varchar(20) NOT NULL,
    is_preferred             bit NOT NULL,
    is_active                bit NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_vendor_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_vendor_vendor_id' AND object_id = OBJECT_ID('dw.dim_vendor'))
    CREATE UNIQUE INDEX ux_dim_vendor_vendor_id ON dw.dim_vendor (vendor_id) WHERE vendor_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_vendor
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_vendor', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_vendor ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_vendor WHERE vendor_key = -1)
            INSERT INTO dw.dim_vendor (vendor_key, vendor_id, row_type, is_in_source, vendor_name, credit_rating,
                             credit_rating_label, is_preferred, is_active, inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', NULL, 'Unknown', 0, 0, @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_vendor OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  BusinessEntityID          AS vendor_id,
                    'Source'                  AS row_type,
                    [Name]                    AS vendor_name,
                    CreditRating              AS credit_rating,
                    CASE CreditRating WHEN 1 THEN 'Superior' WHEN 2 THEN 'Excellent'
                         WHEN 3 THEN 'Above average' WHEN 4 THEN 'Average'
                         WHEN 5 THEN 'Below average' ELSE 'N/A' END AS credit_rating_label,
                    PreferredVendorStatus     AS is_preferred,
                    ActiveFlag                AS is_active
            FROM stg.aw_vendor
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            vendor_name = s.vendor_name,
            credit_rating = s.credit_rating,
            credit_rating_label = s.credit_rating_label,
            is_preferred = s.is_preferred,
            is_active = s.is_active,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_vendor d
        JOIN #src s ON s.vendor_id = d.vendor_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.vendor_name, s.credit_rating, s.credit_rating_label, s.is_preferred,
                   s.is_active, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.vendor_name, d.credit_rating, d.credit_rating_label, d.is_preferred,
                   d.is_active, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_vendor (
            vendor_id, row_type, is_in_source, vendor_name, credit_rating, credit_rating_label,
            is_preferred, is_active, inserted_batch_id, updated_batch_id)
        SELECT
            s.vendor_id, s.row_type, 1, s.vendor_name, s.credit_rating, s.credit_rating_label,
            s.is_preferred, s.is_active, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_vendor d WHERE d.vendor_id = s.vendor_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_vendor d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.vendor_id = d.vendor_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_vendor'))
            SET IDENTITY_INSERT dw.dim_vendor OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
