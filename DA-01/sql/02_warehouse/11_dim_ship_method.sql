/*
  11_dim_ship_method.sql
  dw.dim_ship_method: one row per source ship method, plus special rows.
    Shared by sales and purchases.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key ship_method_key (identity); special rows -1 Unknown.
    - Business key ship_method_id, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_ship_method') IS NULL
CREATE TABLE dw.dim_ship_method (
    ship_method_key          int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_ship_method PRIMARY KEY,
    ship_method_id           int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    ship_method_name         nvarchar(50) NOT NULL,
    ship_base                money NULL,
    ship_rate                money NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_ship_method_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_ship_method_ship_method_id' AND object_id = OBJECT_ID('dw.dim_ship_method'))
    CREATE UNIQUE INDEX ux_dim_ship_method_ship_method_id ON dw.dim_ship_method (ship_method_id) WHERE ship_method_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_ship_method
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_ship_method', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_ship_method ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_ship_method WHERE ship_method_key = -1)
            INSERT INTO dw.dim_ship_method (ship_method_key, ship_method_id, row_type, is_in_source, ship_method_name, ship_base,
                             ship_rate, inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', NULL, NULL, @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_ship_method OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  ShipMethodID   AS ship_method_id,
                    'Source'       AS row_type,
                    [Name]         AS ship_method_name,
                    ShipBase       AS ship_base,
                    ShipRate       AS ship_rate
            FROM stg.aw_ship_method
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            ship_method_name = s.ship_method_name,
            ship_base = s.ship_base,
            ship_rate = s.ship_rate,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_ship_method d
        JOIN #src s ON s.ship_method_id = d.ship_method_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.ship_method_name, s.ship_base, s.ship_rate, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.ship_method_name, d.ship_base, d.ship_rate, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_ship_method (
            ship_method_id, row_type, is_in_source, ship_method_name, ship_base, ship_rate,
            inserted_batch_id, updated_batch_id)
        SELECT
            s.ship_method_id, s.row_type, 1, s.ship_method_name, s.ship_base, s.ship_rate,
            @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_ship_method d WHERE d.ship_method_id = s.ship_method_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_ship_method d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.ship_method_id = d.ship_method_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_ship_method'))
            SET IDENTITY_INSERT dw.dim_ship_method OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
