/*
  08_dim_territory.sql
  dw.dim_territory: one row per source territory, plus special rows.
    Business key territory_code: the TerritoryID as text for the 10 territories, and
    "REGION-" + region group name for one region-level row per region group
    (row_type Derived, country "Multiple"). Region-level rows hold the regional sales
    managers' quotas (D32, D61). New region groups get their row automatically.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key territory_key (identity); special rows -1 Unknown.
    - Business key territory_code, unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_territory') IS NULL
CREATE TABLE dw.dim_territory (
    territory_key            int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_territory PRIMARY KEY,
    territory_code           varchar(60) NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    territory_id             int NULL,
    territory_name           nvarchar(80) NOT NULL,
    country_code             nvarchar(3) NOT NULL,
    country_name             nvarchar(50) NOT NULL,
    region_group             nvarchar(50) NOT NULL,
    is_region_level          bit NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_territory_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_territory_territory_code' AND object_id = OBJECT_ID('dw.dim_territory'))
    CREATE UNIQUE INDEX ux_dim_territory_territory_code ON dw.dim_territory (territory_code) WHERE territory_code IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_territory
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_territory', @log_id OUTPUT;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_territory ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_territory WHERE territory_key = -1)
            INSERT INTO dw.dim_territory (territory_key, territory_code, row_type, is_in_source, territory_id, territory_name,
                             country_code, country_name, region_group, is_region_level, inserted_batch_id,
                             updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, NULL, N'Unknown', N'N/A', N'Unknown', N'Unknown', 0, @batch_id,
                    @batch_id);
        SET IDENTITY_INSERT dw.dim_territory OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  CAST(t.TerritoryID AS varchar(60))    AS territory_code,
                    'Source'                              AS row_type,
                    t.TerritoryID                         AS territory_id,
                    CAST(t.[Name] AS nvarchar(80))        AS territory_name,
                    t.CountryRegionCode                   AS country_code,
                    cr.[Name]                             AS country_name,
                    t.[Group]                             AS region_group,
                    CAST(0 AS bit)                        AS is_region_level
            FROM stg.aw_sales_territory t
            LEFT JOIN stg.aw_country_region cr ON cr.CountryRegionCode = t.CountryRegionCode
            UNION ALL
            SELECT  CAST('REGION-' + UPPER(REPLACE(g.[Group], ' ', '_')) AS varchar(60)),
                    'Derived',
                    NULL,
                    CAST(g.[Group] + N' (region level)' AS nvarchar(80)),
                    N'N/A',
                    N'Multiple',
                    g.[Group],
                    CAST(1 AS bit)
            FROM (SELECT DISTINCT [Group] FROM stg.aw_sales_territory) g
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            territory_id = s.territory_id,
            territory_name = s.territory_name,
            country_code = s.country_code,
            country_name = s.country_name,
            region_group = s.region_group,
            is_region_level = s.is_region_level,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_territory d
        JOIN #src s ON s.territory_code = d.territory_code
        WHERE NOT EXISTS (
            SELECT s.row_type, s.territory_id, s.territory_name, s.country_code, s.country_name,
                   s.region_group, s.is_region_level, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.territory_id, d.territory_name, d.country_code, d.country_name,
                   d.region_group, d.is_region_level, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_territory (
            territory_code, row_type, is_in_source, territory_id, territory_name, country_code,
            country_name, region_group, is_region_level, inserted_batch_id, updated_batch_id)
        SELECT
            s.territory_code, s.row_type, 1, s.territory_id, s.territory_name, s.country_code,
            s.country_name, s.region_group, s.is_region_level, @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_territory d WHERE d.territory_code = s.territory_code);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_territory d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.territory_code = d.territory_code);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_territory'))
            SET IDENTITY_INSERT dw.dim_territory OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
