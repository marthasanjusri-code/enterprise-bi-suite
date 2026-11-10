/*
  21_dim_organization.sql
  etl.org_territory_map: reference table linking each finance leaf unit to a sales territory.
  dw.dim_organization: one row per source organization unit, plus a special row.
    Source: AdventureWorksDW2025 DimOrganization + DimCurrency, copied to
    stg.awdw_dim_organization and stg.awdw_dim_currency. Used by fact_finance.
    Needs dw.dim_territory to be loaded first (the map points to its territory_code).

  Hierarchy (D69): the tree is ragged (the US divisions sit one level deeper), so it is
    flattened into level_1 to level_3 below the top company, repeating the unit's own
    name where a level does not exist. The top company repeats its own name.
    At most four levels (top unit plus three) are supported; the load stops with an
    error if the source has more, or a unit that cannot be reached from the top.

  Territory mapping (D69, D71 to D73): the 9 leaf units correspond to 9 sales territories,
    but the numbers differ between the two databases (finance Northeast = 3, sales
    territory code 3 = Central), so units are linked by an explicit, reviewable table,
    never by number or by name rules. Parent units have no single territory ("N/A").
  Region group (used by row-level security):
    - leaf unit: the region group of its mapped territory;
    - parent unit: the one region group shared by all its leaf units, or "All regions"
      when they differ (the top company);
    - a leaf unit missing from the map gets "N/A": it matches no region, so no regional
      manager sees it (fails closed). The tests and data quality checks report such units.

  Common pattern for all source dimensions (D59, D83, D84, D87):
    - Surrogate key organization_key (identity); special row -1 Unknown.
    - Business key organization_id (the source OrganizationKey), unique for real rows.
    - Load: UPDATE changed rows, then INSERT new rows, then mark rows that left the
      source with is_in_source = 0 (soft delete, rows are never removed).
    - Lineage: inserted_batch_id, updated_batch_id.
  Missing text becomes "N/A" (D89).
  Safe to re-run: tables are created once, map values are set to the ones below,
  the procedure is replaced.
*/

USE EnterpriseBI_DW;
GO

IF OBJECT_ID('etl.org_territory_map') IS NULL
CREATE TABLE etl.org_territory_map (
    organization_id    int           NOT NULL CONSTRAINT pk_org_territory_map PRIMARY KEY,
    organization_name  nvarchar(50)  NOT NULL,
    territory_code     varchar(60)   NOT NULL
);
GO

-- organization_name is kept for readability and is checked against the source by the tests.
-- territory_code is the dw.dim_territory business key (the sales TerritoryID as text).
WITH v (organization_id, organization_name, territory_code) AS (
    SELECT * FROM (VALUES
        (3,  N'Northeast Division', '2'),
        (4,  N'Northwest Division', '1'),
        (5,  N'Central Division',   '3'),
        (6,  N'Southeast Division', '5'),
        (7,  N'Southwest Division', '4'),
        (8,  N'Canadian Division',  '6'),
        (11, N'France',             '7'),
        (12, N'Germany',            '8'),
        (13, N'Australia',          '9')
    ) x (organization_id, organization_name, territory_code)
)
UPDATE m
SET organization_name = v.organization_name,
    territory_code    = v.territory_code
FROM etl.org_territory_map m
JOIN v ON v.organization_id = m.organization_id
WHERE m.organization_name <> v.organization_name
   OR m.territory_code    <> v.territory_code;

WITH v (organization_id, organization_name, territory_code) AS (
    SELECT * FROM (VALUES
        (3,  N'Northeast Division', '2'),
        (4,  N'Northwest Division', '1'),
        (5,  N'Central Division',   '3'),
        (6,  N'Southeast Division', '5'),
        (7,  N'Southwest Division', '4'),
        (8,  N'Canadian Division',  '6'),
        (11, N'France',             '7'),
        (12, N'Germany',            '8'),
        (13, N'Australia',          '9')
    ) x (organization_id, organization_name, territory_code)
)
INSERT INTO etl.org_territory_map (organization_id, organization_name, territory_code)
SELECT v.organization_id, v.organization_name, v.territory_code
FROM v
WHERE NOT EXISTS (SELECT 1 FROM etl.org_territory_map m WHERE m.organization_id = v.organization_id);
GO

IF OBJECT_ID('dw.dim_organization') IS NULL
CREATE TABLE dw.dim_organization (
    organization_key         int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_organization PRIMARY KEY,
    organization_id          int NULL,
    row_type                 varchar(20) NOT NULL,
    is_in_source             bit NOT NULL,
    organization_name        nvarchar(50) NOT NULL,
    level_1                  nvarchar(50) NOT NULL,
    level_2                  nvarchar(50) NOT NULL,
    level_3                  nvarchar(50) NOT NULL,
    region_group             nvarchar(50) NOT NULL,
    mapped_territory_code    varchar(60) NOT NULL,
    mapped_territory_name    nvarchar(80) NOT NULL,
    currency_code            nvarchar(3) NOT NULL,
    is_leaf                  bit NOT NULL,
    inserted_batch_id        int NOT NULL,
    updated_batch_id         int NOT NULL,
    CONSTRAINT ck_dim_organization_row_type CHECK (row_type IN ('Source', 'Derived', 'Unknown', 'Not applicable'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_dim_organization_organization_id' AND object_id = OBJECT_ID('dw.dim_organization'))
    CREATE UNIQUE INDEX ux_dim_organization_organization_id ON dw.dim_organization (organization_id) WHERE organization_id IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE etl.load_dim_organization
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @log_id int, @rows_read int, @rows_updated int, @rows_inserted int, @rows_retired int;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'dw.dim_organization', @log_id OUTPUT;

        -- Levels below the top unit: each unit with its ancestors at depth 1, 2 and 3.
        IF OBJECT_ID('tempdb..#hier') IS NOT NULL DROP TABLE #hier;

        WITH h AS (
            SELECT  o.OrganizationKey AS organization_id,
                    0 AS depth,
                    CAST(NULL AS nvarchar(50)) AS n1,
                    CAST(NULL AS nvarchar(50)) AS n2,
                    CAST(NULL AS nvarchar(50)) AS n3
            FROM stg.awdw_dim_organization o
            WHERE o.ParentOrganizationKey IS NULL
            UNION ALL
            SELECT  c.OrganizationKey,
                    h.depth + 1,
                    CASE WHEN h.depth + 1 = 1 THEN ISNULL(c.OrganizationName, N'N/A') ELSE h.n1 END,
                    CASE WHEN h.depth + 1 = 2 THEN ISNULL(c.OrganizationName, N'N/A') ELSE h.n2 END,
                    CASE WHEN h.depth + 1 = 3 THEN ISNULL(c.OrganizationName, N'N/A') ELSE h.n3 END
            FROM h
            JOIN stg.awdw_dim_organization c ON c.ParentOrganizationKey = h.organization_id
        )
        SELECT organization_id, depth, n1, n2, n3
        INTO #hier
        FROM h
        OPTION (MAXRECURSION 20);

        -- The shape is a design assumption (D69). Stop if the source breaks it.
        DECLARE @units_in_source int = (SELECT COUNT(*) FROM stg.awdw_dim_organization);
        DECLARE @units_reached int = (SELECT COUNT(*) FROM #hier);
        IF @units_reached <> @units_in_source
           OR EXISTS (SELECT 1 FROM #hier WHERE depth > 3)
            THROW 50001, 'dim_organization supports at most four levels (top unit plus three) and every unit must be reachable from the top unit.', 1;

        -- Every map row must point to a real territory.
        IF EXISTS (SELECT 1 FROM etl.org_territory_map m
                   WHERE NOT EXISTS (SELECT 1 FROM dw.dim_territory t WHERE t.territory_code = m.territory_code))
            THROW 50001, 'etl.org_territory_map points to a territory that is not in dw.dim_territory. Load dim_territory first or correct the map.', 1;

        -- Leaf units with their mapped territory (unmapped leaf units keep NULLs).
        IF OBJECT_ID('tempdb..#leaf') IS NOT NULL DROP TABLE #leaf;

        SELECT  o.OrganizationKey AS node,
                t.territory_code,
                t.territory_name,
                t.region_group
        INTO #leaf
        FROM stg.awdw_dim_organization o
        LEFT JOIN etl.org_territory_map m ON m.organization_id = o.OrganizationKey
        LEFT JOIN dw.dim_territory t ON t.territory_code = m.territory_code
        WHERE NOT EXISTS (SELECT 1 FROM stg.awdw_dim_organization k WHERE k.ParentOrganizationKey = o.OrganizationKey);

        -- Every unit with all units below it (itself included).
        IF OBJECT_ID('tempdb..#tree') IS NOT NULL DROP TABLE #tree;

        WITH t AS (
            SELECT OrganizationKey AS anc, OrganizationKey AS node
            FROM stg.awdw_dim_organization
            UNION ALL
            SELECT t.anc, c.OrganizationKey
            FROM t
            JOIN stg.awdw_dim_organization c ON c.ParentOrganizationKey = t.node
        )
        SELECT anc, node
        INTO #tree
        FROM t
        OPTION (MAXRECURSION 20);

        -- Region groups found among the leaf units below each unit.
        IF OBJECT_ID('tempdb..#grp') IS NOT NULL DROP TABLE #grp;

        SELECT  t.anc AS organization_id,
                COUNT(DISTINCT l.region_group) AS group_count,
                MIN(l.region_group) AS one_group
        INTO #grp
        FROM #tree t
        JOIN #leaf l ON l.node = t.node
        GROUP BY t.anc;

        -- Special rows (fixed keys, created once, never changed by the load).
        SET IDENTITY_INSERT dw.dim_organization ON;
        IF NOT EXISTS (SELECT 1 FROM dw.dim_organization WHERE organization_key = -1)
            INSERT INTO dw.dim_organization (organization_key, organization_id, row_type, is_in_source, organization_name,
                             level_1, level_2, level_3, region_group, mapped_territory_code, mapped_territory_name,
                             currency_code, is_leaf, inserted_batch_id, updated_batch_id)
            VALUES (-1, NULL, 'Unknown', 0, N'Unknown', N'Unknown', N'Unknown', N'Unknown', N'Unknown',
                    'N/A', N'N/A', N'N/A', 0, @batch_id, @batch_id);
        SET IDENTITY_INSERT dw.dim_organization OFF;

        -- Source rows as they should look now.
        IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;

        SELECT  o.OrganizationKey                                            AS organization_id,
                'Source'                                                     AS row_type,
                ISNULL(o.OrganizationName, N'N/A')                           AS organization_name,
                a.l1                                                         AS level_1,
                b.l2                                                         AS level_2,
                c.l3                                                         AS level_3,
                CASE WHEN ISNULL(g.group_count, 0) = 1 THEN g.one_group
                     WHEN ISNULL(g.group_count, 0) > 1 THEN N'All regions'
                     ELSE N'N/A' END                                         AS region_group,
                ISNULL(lf.territory_code, 'N/A')                             AS mapped_territory_code,
                ISNULL(lf.territory_name, N'N/A')                            AS mapped_territory_name,
                ISNULL(CAST(cu.CurrencyAlternateKey AS nvarchar(3)), N'N/A') AS currency_code,
                CAST(CASE WHEN lf.node IS NOT NULL THEN 1 ELSE 0 END AS bit) AS is_leaf
        INTO #src
        FROM stg.awdw_dim_organization o
        JOIN #hier h ON h.organization_id = o.OrganizationKey
        CROSS APPLY (SELECT ISNULL(h.n1, ISNULL(o.OrganizationName, N'N/A')) AS l1) a
        CROSS APPLY (SELECT ISNULL(h.n2, a.l1) AS l2) b
        CROSS APPLY (SELECT ISNULL(h.n3, b.l2) AS l3) c
        LEFT JOIN #grp g ON g.organization_id = o.OrganizationKey
        LEFT JOIN #leaf lf ON lf.node = o.OrganizationKey
        LEFT JOIN stg.awdw_dim_currency cu ON cu.CurrencyKey = o.CurrencyKey;
        SET @rows_read = @@ROWCOUNT;

        -- 1. Update rows whose values changed, or that came back to the source.
        UPDATE d
        SET row_type = s.row_type,
            organization_name = s.organization_name,
            level_1 = s.level_1,
            level_2 = s.level_2,
            level_3 = s.level_3,
            region_group = s.region_group,
            mapped_territory_code = s.mapped_territory_code,
            mapped_territory_name = s.mapped_territory_name,
            currency_code = s.currency_code,
            is_leaf = s.is_leaf,
            is_in_source = 1,
            updated_batch_id = @batch_id
        FROM dw.dim_organization d
        JOIN #src s ON s.organization_id = d.organization_id
        WHERE NOT EXISTS (
            SELECT s.row_type, s.organization_name, s.level_1, s.level_2, s.level_3, s.region_group,
                   s.mapped_territory_code, s.mapped_territory_name, s.currency_code, s.is_leaf, CAST(1 AS bit)
            INTERSECT
            SELECT d.row_type, d.organization_name, d.level_1, d.level_2, d.level_3, d.region_group,
                   d.mapped_territory_code, d.mapped_territory_name, d.currency_code, d.is_leaf, d.is_in_source);
        SET @rows_updated = @@ROWCOUNT;

        -- 2. Insert new rows.
        INSERT INTO dw.dim_organization (
            organization_id, row_type, is_in_source, organization_name, level_1, level_2, level_3,
            region_group, mapped_territory_code, mapped_territory_name, currency_code, is_leaf,
            inserted_batch_id, updated_batch_id)
        SELECT
            s.organization_id, s.row_type, 1, s.organization_name, s.level_1, s.level_2, s.level_3,
            s.region_group, s.mapped_territory_code, s.mapped_territory_name, s.currency_code, s.is_leaf,
            @batch_id, @batch_id
        FROM #src s
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_organization d WHERE d.organization_id = s.organization_id);
        SET @rows_inserted = @@ROWCOUNT;

        -- 3. Soft delete: rows no longer in the source are kept but marked.
        UPDATE d
        SET is_in_source = 0,
            updated_batch_id = @batch_id
        FROM dw.dim_organization d
        WHERE d.row_type IN ('Source', 'Derived')
          AND d.is_in_source = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.organization_id = d.organization_id);
        SET @rows_retired = @@ROWCOUNT;

        DECLARE @rows_written int = @rows_updated + @rows_inserted + @rows_retired;
        EXEC etl.end_step @log_id, 'Succeeded', @rows_read, @rows_written;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        IF EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = OBJECT_ID('dw.dim_organization'))
            SET IDENTITY_INSERT dw.dim_organization OFF;
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO
