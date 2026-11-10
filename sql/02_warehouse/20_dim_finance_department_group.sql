/*
  20_dim_finance_department_group.sql
  dw.dim_finance_department_group: one row per source department group, plus a special row.
    Source: AdventureWorksDW2025 DimDepartmentGroup, copied to stg.awdw_dim_department_group.
    Used by fact_finance. Not the same as dw.dim_department (HumanResources departments).

  Hierarchy (D70): level_1 is the top group (Corporate), level_2 is the group itself.
    The top group's own rows are separate data, not a copy of its children (D35), so its
    row is shown at level 2 as "Corporate (direct)" with is_corporate_direct = 1.
    The Corporate total in a report is the level 1 member, which adds all level 2 rows.
  The source hierarchy has exactly two levels. The load stops with an error if that
  ever changes, because a third level would not fit level_1 / level_2.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key finance_department_group_key (identity); special row -1 Unknown.
    - Business key department_group_id (the source DepartmentGroupKey), unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Missing text becomes "N/A" (D89).
  Safe to re-run: the table is created once; the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('dw.dim_finance_department_group') IS NULL
CREATE TABLE dw.dim_finance_department_group (
    finance_department_group_key int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_finance_department_group PRIMARY KEY,
    department_group_id          int NULL,
    row_type                     varchar(20) NOT NULL,
    is_in_source                 bit NOT NULL,
    level_1                      nvarchar(60) NOT NULL,
    level_2                      nvarchar(60) NOT NULL,
    is_corporate_direct          bit NOT NULL,
    inserted_batch_id            int NOT NULL,
    updated_batch_id             int NOT NULL,
    CONSTRAINT ck_dim_finance_department_group_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_finance_department_group_department_group_id' AND object_id = OBJECT_ID('dw.dim_finance_department_group'))
    CREATE UNIQUE INDEX ux_dim_finance_department_group_department_group_id ON dw.dim_finance_department_group (department_group_id) WHERE department_group_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_finance_department_group
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_finance_department_group', @log_id OUTPUT;

        -- The two-level shape is a design assumption (D70). Stop if the source breaks it:
        -- a group whose parent is missing, or whose parent has a parent of its own.
        IF EXISTS (
            SELECT 1
            FROM stg.awdw_dim_department_group g
            LEFT JOIN stg.awdw_dim_department_group p ON p.DepartmentGroupKey = g.ParentDepartmentGroupKey
            WHERE g.ParentDepartmentGroupKey IS NOT NULL
              AND (p.DepartmentGroupKey IS NULL OR p.ParentDepartmentGroupKey IS NOT NULL))
            THROW 50001, 'dim_finance_department_group expects a two-level hierarchy: every group has no parent, or a parent that has no parent.', 1;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_finance_department_group ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_finance_department_group WHERE finance_department_group_key = -1)
            INSERT INTO dw.dim_finance_department_group (finance_department_group_key, department_group_id, row_type, is_in_source,
                             level_1, level_2, is_corporate_direct, inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', N'Unknown', 0, @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_finance_department_group OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT *
        INTO #src
        FROM (
            SELECT  g.DepartmentGroupKey                                            AS department_group_id,
                    'Source'                                                        AS row_type,
                    ISNULL(ISNULL(p.DepartmentGroupName, g.DepartmentGroupName), N'N/A') AS level_1,
                    CASE WHEN g.ParentDepartmentGroupKey IS NULL
                         THEN ISNULL(g.DepartmentGroupName, N'N/A') + N' (direct)'
                         ELSE ISNULL(g.DepartmentGroupName, N'N/A') END             AS level_2,
                    CAST(CASE WHEN g.ParentDepartmentGroupKey IS NULL THEN 1 ELSE 0 END AS bit) AS is_corporate_direct
            FROM stg.awdw_dim_department_group g
            LEFT JOIN stg.awdw_dim_department_group p ON p.DepartmentGroupKey = g.ParentDepartmentGroupKey
        ) x;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            level_1 = s.level_1,
            level_2 = s.level_2,
            is_corporate_direct = s.is_corporate_direct,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_finance_department_group d
        JOIN #src s ON s.department_group_id = d.department_group_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.level_1, s.level_2, s.is_corporate_direct, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.level_1, d.level_2, d.is_corporate_direct, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_finance_department_group (
            department_group_id, row_type, is_in_source, level_1, level_2, is_corporate_direct,
            inserted_batch_id, updated_batch_id)
        SELECT
            s.department_group_id, s.row_type, 1, s.level_1, s.level_2, s.is_corporate_direct,
            @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_finance_department_group d WHERE d.department_group_id = s.department_group_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_finance_department_group d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.department_group_id = d.department_group_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_finance_department_group'))
            SET IDENTITY_INSERT dw.dim_finance_department_group OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
