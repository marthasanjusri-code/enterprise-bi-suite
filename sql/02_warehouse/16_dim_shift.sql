/*
  16_dim_shift.sql
  dw.dim_shift: one row per source shift, plus special rows.
    Work shifts with start and end time (the night shift crosses midnight).

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key shift_key (identity); special rows -1 Unknown.
    - Business key shift_id, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_shift') IS NULL
CREATE TABLE dw.dim_shift (
    shift_key                int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_shift PRIMARY KEY,
    shift_id                 int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    shift_name               nvarchar(50) NOT NULL,
    start_time               time(7) NULL,
    end_time                 time(7) NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_shift_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_shift_shift_id' AND object_id = OBJECT_ID('dw.dim_shift'))
    CREATE UNIQUE INDEX ux_dim_shift_shift_id ON dw.dim_shift (shift_id) WHERE shift_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_shift
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_shift', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_shift ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_shift WHERE shift_key = -1)
            INSERT INTO dw.dim_shift (shift_key, shift_id, row_type, is_in_source, shift_name, start_time, end_time,
                             inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', NULL, NULL, @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_shift OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  ShiftID         AS shift_id,
                    'Source'        AS row_type,
                    [Name]          AS shift_name,
                    StartTime       AS start_time,
                    EndTime         AS end_time
            FROM stg.aw_shift
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            shift_name = s.shift_name,
            start_time = s.start_time,
            end_time = s.end_time,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_shift d
        JOIN #src s ON s.shift_id = d.shift_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.shift_name, s.start_time, s.end_time, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.shift_name, d.start_time, d.end_time, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_shift (
            shift_id, row_type, is_in_source, shift_name, start_time, end_time, inserted_batch_id,
            updated_batch_id)
        SELECT
            s.shift_id, s.row_type, 1, s.shift_name, s.start_time, s.end_time, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_shift d WHERE d.shift_id = s.shift_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_shift d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.shift_id = d.shift_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_shift'))
            SET IDENTITY_INSERT dw.dim_shift OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
