/*
  19_dim_scenario.sql
  dw.dim_scenario: one row per source scenario (Actual, Budget, Forecast), plus a special row.
    Source: AdventureWorksDW2025 DimScenario, copied to stg.awdw_dim_scenario.
    Used by fact_finance. Forecast had no finance rows at design time; it is kept so that
    forecast data arriving later has a row to link to.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key scenario_key (identity); special rows -1 Unknown.
    - Business key scenario_id (the source ScenarioKey), unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Missing text becomes "N/A" (D89).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_scenario') IS NULL
CREATE TABLE dw.dim_scenario (
    scenario_key             int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_scenario PRIMARY KEY,
    scenario_id              int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    scenario_name            nvarchar(50) NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_scenario_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_scenario_scenario_id' AND object_id = OBJECT_ID('dw.dim_scenario'))
    CREATE UNIQUE INDEX ux_dim_scenario_scenario_id ON dw.dim_scenario (scenario_id) WHERE scenario_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_scenario
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_scenario', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_scenario ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_scenario WHERE scenario_key = -1)
            INSERT INTO dw.dim_scenario (scenario_key, scenario_id, row_type, is_in_source, scenario_name,
                             inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_scenario OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  ScenarioKey                    AS scenario_id,
                    'Source'                       AS row_type,
                    ISNULL(ScenarioName, N'N/A')   AS scenario_name
            FROM stg.awdw_dim_scenario
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            scenario_name = s.scenario_name,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_scenario d
        JOIN #src s ON s.scenario_id = d.scenario_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.scenario_name, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.scenario_name, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_scenario (
            scenario_id, row_type, is_in_source, scenario_name, inserted_batch_id,
            updated_batch_id)
        SELECT
            s.scenario_id, s.row_type, 1, s.scenario_name, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_scenario d WHERE d.scenario_id = s.scenario_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_scenario d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.scenario_id = d.scenario_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_scenario'))
            SET IDENTITY_INSERT dw.dim_scenario OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
