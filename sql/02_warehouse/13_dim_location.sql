/*
  13_dim_location.sql
  dw.dim_location: one row per source location, plus special rows.
    location_type: Work centre when cost rate or available hours are above 0, else
    Storage (D50). Special row -2 "No stock location" holds the zero-stock rows of
    active products without inventory (D52).

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key location_key (identity); special rows -1 Unknown, -2 Not applicable.
    - Business key location_id, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_location') IS NULL
CREATE TABLE dw.dim_location (
    location_key             int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_location PRIMARY KEY,
    location_id              int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    location_name            nvarchar(50) NOT NULL,
    location_type            varchar(15) NOT NULL,
    cost_rate                smallmoney NULL,
    availability             decimal(8,2) NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_location_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_location_location_id' AND object_id = OBJECT_ID('dw.dim_location'))
    CREATE UNIQUE INDEX ux_dim_location_location_id ON dw.dim_location (location_id) WHERE location_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_location
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_location', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_location ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_location WHERE location_key = -1)
            INSERT INTO dw.dim_location (location_key, location_id, row_type, is_in_source, location_name, location_type,
                             cost_rate, availability, inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', 'Unknown', NULL, NULL, @batch_id, @batch_id);
        IF NOT EXISTS (SELECT 1 FROM dw.dim_location WHERE location_key = -2)
            INSERT INTO dw.dim_location (location_key, location_id, row_type, is_in_source, location_name, location_type,
                             cost_rate, availability, inserted_batch_id, updated_batch_id)
            VALUES (-2, NULL, 'Not applicable', 0, N'No stock location', 'Not applicable', NULL, NULL,
                    @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_location OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  LocationID      AS location_id,
                    'Source'        AS row_type,
                    [Name]          AS location_name,
                    CASE WHEN CostRate > 0 OR Availability > 0 THEN 'Work centre' ELSE 'Storage' END AS location_type,
                    CostRate        AS cost_rate,
                    Availability    AS availability
            FROM stg.aw_location
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            location_name = s.location_name,
            location_type = s.location_type,
            cost_rate = s.cost_rate,
            availability = s.availability,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_location d
        JOIN #src s ON s.location_id = d.location_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.location_name, s.location_type, s.cost_rate, s.availability, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.location_name, d.location_type, d.cost_rate, d.availability, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_location (
            location_id, row_type, is_in_source, location_name, location_type, cost_rate,
            availability, inserted_batch_id, updated_batch_id)
        SELECT
            s.location_id, s.row_type, 1, s.location_name, s.location_type, s.cost_rate,
            s.availability, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_location d WHERE d.location_id = s.location_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_location d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.location_id = d.location_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_location'))
            SET IDENTITY_INSERT dw.dim_location OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
