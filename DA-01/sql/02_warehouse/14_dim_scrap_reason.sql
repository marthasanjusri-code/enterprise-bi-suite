/*
  14_dim_scrap_reason.sql
  dw.dim_scrap_reason: one row per source scrap reason, plus special rows.
    Special row -2 "No scrap" for work orders without scrap (D59).

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key scrap_reason_key (identity); special rows -1 Unknown, -2 Not applicable.
    - Business key scrap_reason_id, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_scrap_reason') IS NULL
CREATE TABLE dw.dim_scrap_reason (
    scrap_reason_key         int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_scrap_reason PRIMARY KEY,
    scrap_reason_id          int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    scrap_reason_name        nvarchar(50) NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_scrap_reason_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_scrap_reason_scrap_reason_id' AND object_id = OBJECT_ID('dw.dim_scrap_reason'))
    CREATE UNIQUE INDEX ux_dim_scrap_reason_scrap_reason_id ON dw.dim_scrap_reason (scrap_reason_id) WHERE scrap_reason_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_scrap_reason
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_scrap_reason', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_scrap_reason ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_scrap_reason WHERE scrap_reason_key = -1)
            INSERT INTO dw.dim_scrap_reason (scrap_reason_key, scrap_reason_id, row_type, is_in_source, scrap_reason_name,
                             inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', @batch_id, @batch_id);
        IF NOT EXISTS (SELECT 1 FROM dw.dim_scrap_reason WHERE scrap_reason_key = -2)
            INSERT INTO dw.dim_scrap_reason (scrap_reason_key, scrap_reason_id, row_type, is_in_source, scrap_reason_name,
                             inserted_batch_id, updated_batch_id)
            VALUES (-2, NULL, 'Not applicable', 0, N'No scrap', @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_scrap_reason OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  ScrapReasonID   AS scrap_reason_id,
                    'Source'        AS row_type,
                    [Name]          AS scrap_reason_name
            FROM stg.aw_scrap_reason
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            scrap_reason_name = s.scrap_reason_name,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_scrap_reason d
        JOIN #src s ON s.scrap_reason_id = d.scrap_reason_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.scrap_reason_name, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.scrap_reason_name, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_scrap_reason (
            scrap_reason_id, row_type, is_in_source, scrap_reason_name, inserted_batch_id,
            updated_batch_id)
        SELECT
            s.scrap_reason_id, s.row_type, 1, s.scrap_reason_name, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_scrap_reason d WHERE d.scrap_reason_id = s.scrap_reason_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_scrap_reason d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.scrap_reason_id = d.scrap_reason_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_scrap_reason'))
            SET IDENTITY_INSERT dw.dim_scrap_reason OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
