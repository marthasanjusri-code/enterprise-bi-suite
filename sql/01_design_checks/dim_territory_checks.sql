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