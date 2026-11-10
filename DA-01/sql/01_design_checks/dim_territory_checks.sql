/*
  dim_territory_checks.sql
  Design checks for dw.dim_territory: the 10 sales territories, their
  countries and region groups, and the extra row in the DW territory table.

  Sources: AdventureWorks2025, AdventureWorksDW2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- dim_territory: one row per territory, plus region-level rows (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. Territories with country name and region group.
SELECT  t.TerritoryID,
        t.Name              AS territory,
        t.CountryRegionCode AS country_code,
        cr.Name             AS country,
        t.[Group]           AS region_group
FROM Sales.SalesTerritory t
JOIN Person.CountryRegion cr ON cr.CountryRegionCode = t.CountryRegionCode
ORDER BY t.[Group], t.Name;

-- 2. The DW territory table has 11 rows, OLTP has 10. What is the extra one?
SELECT  SalesTerritoryKey,
        SalesTerritoryAlternateKey,
        SalesTerritoryRegion,
        SalesTerritoryCountry,
        SalesTerritoryGroup
FROM AdventureWorksDW2025.dbo.DimSalesTerritory
ORDER BY SalesTerritoryKey;
GO
-- Results (03 Nov 2026):
--   1. 10 territories: Europe (France, Germany, United Kingdom), North
--      America (Canada + 5 US territories), Pacific (Australia).
--   2. The 11th DW row is key 11, alternate key 0, all names "NA": an
--      unknown member, as expected. Closes the open item.
-- Decisions:
--   - Special keys used in every dimension: -1 = "Unknown" (data missing),
--     -2 = "Not applicable" (no value can exist, e.g. online orders have no
--     salesperson, work orders without scrap have no scrap reason).
--   - 3 region-level rows (North America, Europe, Pacific) with their own
--     keys, is_region_level = 1, country "Multiple".