/*
  02_value_profiling.sql
  Checks the actual values in columns whose meaning affects the warehouse design
  (status codes, currencies, region links, code lists, finance attributes).

  Read-only. Results are recorded in docs/source_inventory.xlsx.
*/


-- =====================================================================
-- Status codes (decoded with the source system's own functions)
-- =====================================================================

-- Result (29 Oct 2026): all 31,465 sales orders are status 5 (Shipped).
USE AdventureWorks2025;
GO

SELECT  Status,
        dbo.ufnGetSalesOrderStatusText(Status) AS status_text,
        COUNT(*)                               AS order_count
FROM Sales.SalesOrderHeader
GROUP BY Status
ORDER BY Status;

-- Result (29 Oct 2026): 1 Pending 225, 2 Approved 12, 3 Rejected 86, 4 Complete 3,689.
SELECT  Status,
        dbo.ufnGetPurchaseOrderStatusText(Status) AS status_text,
        COUNT(*)                                  AS order_count
FROM Purchasing.PurchaseOrderHeader
GROUP BY Status
ORDER BY Status;
GO


-- =====================================================================
-- Sales orders: date range, volume per year, empty columns
-- =====================================================================

SELECT  MIN(OrderDate)                                         AS first_order,
        MAX(OrderDate)                                         AS last_order,
        COUNT(*)                                               AS orders,
        SUM(CASE WHEN CurrencyRateID IS NULL THEN 1 ELSE 0 END) AS orders_without_rate,
        SUM(CASE WHEN Comment        IS NULL THEN 1 ELSE 0 END) AS orders_without_comment,
        SUM(CASE WHEN SalesPersonID  IS NULL THEN 1 ELSE 0 END) AS orders_without_salesperson
FROM Sales.SalesOrderHeader;

-- Result (29 Oct 2026): 30 May 2022 to 29 Jun 2025. 2022 and 2025 are partial years.
-- Comment is empty on every order; 27,659 orders (online) have no salesperson.

-- Needed for YTD / YoY: are all years complete?
SELECT  YEAR(OrderDate)          AS order_year,
        MIN(OrderDate)           AS first_order,
        MAX(OrderDate)           AS last_order,
        COUNT(*)                 AS orders,
        SUM(TotalDue)            AS total_due
FROM Sales.SalesOrderHeader
GROUP BY YEAR(OrderDate)
ORDER BY order_year;
GO


-- =====================================================================
-- Currency: are order amounts already in one currency?
-- =====================================================================

-- Result (29 Oct 2026): ratio 0.98 to 1.00 for USD, AUD, CAD, GBP, DEM, FRF.
-- Amounts are stored in USD; exchange rates are not needed for reporting.
-- Online orders without discount sell at list price.
-- If price / list price is about the same for every currency,
-- amounts are stored in the base currency (USD), not local currency.
-- ISNULL returns the type of its first argument (nchar(3)), which cut
-- '(no rate)' to '(no'. Cast first so the label fits.
SELECT  ISNULL(CAST(cr.FromCurrencyCode AS nvarchar(10)), N'(no rate)') AS from_currency,
        ISNULL(CAST(cr.ToCurrencyCode   AS nvarchar(10)), N'(no rate)') AS to_currency,
        COUNT(*)                                 AS order_lines,
        AVG(CAST(d.UnitPrice AS decimal(19,4))
            / NULLIF(CAST(p.ListPrice AS decimal(19,4)), 0)) AS avg_price_to_list
FROM Sales.SalesOrderDetail d
JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
JOIN Production.Product p     ON p.ProductID    = d.ProductID
LEFT JOIN Sales.CurrencyRate cr ON cr.CurrencyRateID = h.CurrencyRateID
WHERE h.OnlineOrderFlag = 1
  AND d.UnitPriceDiscount = 0
GROUP BY cr.FromCurrencyCode, cr.ToCurrencyCode
ORDER BY order_lines DESC;
GO


-- =====================================================================
-- Region link: customer territory vs order territory
-- =====================================================================

-- Result (29 Oct 2026): 0 customers or orders without territory;
-- order territory never differs from customer territory.
-- Decides which TerritoryID drives row-level security.
SELECT  COUNT(*)                                          AS customers,
        SUM(CASE WHEN TerritoryID IS NULL THEN 1 ELSE 0 END) AS customers_without_territory
FROM Sales.Customer;

SELECT  COUNT(*)                                                    AS orders,
        SUM(CASE WHEN h.TerritoryID IS NULL THEN 1 ELSE 0 END)      AS orders_without_territory,
        SUM(CASE WHEN h.TerritoryID <> c.TerritoryID THEN 1 ELSE 0 END) AS order_territory_differs
FROM Sales.SalesOrderHeader h
JOIN Sales.Customer c ON c.CustomerID = h.CustomerID;
GO


-- =====================================================================
-- Code lists: product attributes, person type, pay frequency, vendor rating
-- =====================================================================

-- Result (29 Oct 2026): ProductLine null 226, M 91, R 100, S 35, T 52.
-- Class null 257, H 82, L 97, M 68. 0 products have DiscontinuedDate; 98 have SellEndDate.
-- PersonType IN 18,484, SC 753, GC 289, EM 273, VC 156, SP 17 (EM + SP = 290 employees).
-- PayFrequency 1: 180 rows, rate 6.50-15.00; 2: 136 rows, rate 8.62-125.50.
-- CreditRating 1: 84, 2: 9, 3: 7, 4: 2, 5: 2 (104 vendors).
-- Code meanings are confirmed from column descriptions (see end of file).

-- Columns are nchar(2); cast before ISNULL so '(null)' is not cut to '(n'.
SELECT 'ProductLine' AS attribute, ISNULL(CAST(ProductLine AS nvarchar(10)), N'(null)') AS value, COUNT(*) AS row_count
FROM Production.Product GROUP BY ProductLine
UNION ALL
SELECT 'Class', ISNULL(CAST(Class AS nvarchar(10)), N'(null)'), COUNT(*)
FROM Production.Product GROUP BY Class
UNION ALL
SELECT 'Style', ISNULL(CAST(Style AS nvarchar(10)), N'(null)'), COUNT(*)
FROM Production.Product GROUP BY Style
ORDER BY attribute, value;

SELECT  COUNT(*)                AS products,
        COUNT(DiscontinuedDate) AS with_discontinued_date,
        COUNT(SellEndDate)      AS with_sell_end_date
FROM Production.Product;

SELECT PersonType, COUNT(*) AS people
FROM Person.Person
GROUP BY PersonType
ORDER BY people DESC;

SELECT  PayFrequency,
        COUNT(*)  AS pay_records,
        MIN(Rate) AS min_rate,
        MAX(Rate) AS max_rate,
        AVG(Rate) AS avg_rate
FROM HumanResources.EmployeePayHistory
GROUP BY PayFrequency;

SELECT CreditRating, COUNT(*) AS vendors
FROM Purchasing.Vendor
GROUP BY CreditRating
ORDER BY CreditRating;
GO


-- =====================================================================
-- Finance source (DW): organizations, accounts, coverage
-- =====================================================================

USE AdventureWorksDW2025;
GO

-- Result (29 Oct 2026): 14 units. 9 leaf units match sales territories
-- (5 US divisions, Canada, France, Germany, Australia). No unit for United Kingdom.
-- Units use USD, CAD, EUR or AUD.
-- 14 rows. Needed to map finance units to sales regions.
SELECT  o.OrganizationKey,
        o.ParentOrganizationKey,
        o.OrganizationName,
        c.CurrencyAlternateKey AS currency
FROM dbo.DimOrganization o
LEFT JOIN dbo.DimCurrency c ON c.CurrencyKey = o.CurrencyKey
ORDER BY o.OrganizationKey;

SELECT Operator, ValueType, COUNT(*) AS accounts
FROM dbo.DimAccount
GROUP BY Operator, ValueType
ORDER BY accounts DESC;

-- Result (29 Oct 2026): Operator '+' 86, '-' 7, '~' 6 accounts (4 of them Units).

-- Result (29 Oct 2026): Actual 29 Dec 2010 to 28 Dec 2013 (34,563 rows),
-- Budget 29 Dec 2010 to 29 Nov 2011 (4,846 rows). Does NOT overlap sales (2022-2025).
-- Does finance cover the same years as sales?
SELECT  s.ScenarioName,
        MIN(f.Date) AS first_date,
        MAX(f.Date) AS last_date,
        COUNT(*)    AS row_count
FROM dbo.FactFinance f
JOIN dbo.DimScenario s ON s.ScenarioKey = f.ScenarioKey
GROUP BY s.ScenarioName
ORDER BY s.ScenarioName;
GO


-- =====================================================================
-- Inventory snapshot (DW): product mapping and date range
-- =====================================================================

-- Result (29 Oct 2026): 606 DW product keys map to all 504 OLTP products.
-- Snapshot runs 28 Dec 2010 to 30 Jun 2014. Does NOT overlap sales (2022-2025).
-- Every DW product key should map to an OLTP product via ProductNumber.
SELECT  COUNT(DISTINCT f.ProductKey) AS dw_products_in_snapshot,
        COUNT(DISTINCT p.ProductID)  AS matched_oltp_products,
        MIN(f.MovementDate)          AS first_date,
        MAX(f.MovementDate)          AS last_date
FROM AdventureWorksDW2025.dbo.FactProductInventory f
JOIN AdventureWorksDW2025.dbo.DimProduct dp ON dp.ProductKey = f.ProductKey
LEFT JOIN AdventureWorks2025.Production.Product p
       ON p.ProductNumber = dp.ProductAlternateKey;
GO


-- =====================================================================
-- Date offset between DW and OLTP (same orders, different dates?)
-- =====================================================================

-- DW finance and inventory dates are 2010-2014; OLTP sales are 2022-2025.
-- Match the same orders by SalesOrderNumber and measure the date gap.
-- One single offset value = DW dates can be shifted safely to align.
SELECT  'Internet' AS channel,
        DATEDIFF(day, f.OrderDate, h.OrderDate) AS day_offset,
        COUNT(*)                                AS order_lines
FROM AdventureWorksDW2025.dbo.FactInternetSales f
JOIN AdventureWorks2025.Sales.SalesOrderHeader h
  ON h.SalesOrderNumber = f.SalesOrderNumber
GROUP BY DATEDIFF(day, f.OrderDate, h.OrderDate)
UNION ALL
SELECT  'Reseller',
        DATEDIFF(day, f.OrderDate, h.OrderDate),
        COUNT(*)
FROM AdventureWorksDW2025.dbo.FactResellerSales f
JOIN AdventureWorks2025.Sales.SalesOrderHeader h
  ON h.SalesOrderNumber = f.SalesOrderNumber
GROUP BY DATEDIFF(day, f.OrderDate, h.OrderDate)
ORDER BY channel, order_lines DESC;
GO


-- =====================================================================
-- Official meaning of code columns (column descriptions in the source)
-- =====================================================================

-- AdventureWorks documents its columns as extended properties (MS_Description).
USE AdventureWorks2025;
GO

SELECT  OBJECT_SCHEMA_NAME(ep.major_id) + '.' + OBJECT_NAME(ep.major_id) AS table_name,
        c.name                                                        AS column_name,
        CAST(ep.value AS nvarchar(500))                               AS description
FROM sys.extended_properties ep
JOIN sys.columns c ON c.object_id = ep.major_id
                  AND c.column_id = ep.minor_id
WHERE ep.name = 'MS_Description'
  AND ep.class = 1
  AND c.name IN ('ProductLine', 'Class', 'Style', 'PersonType',
                 'PayFrequency', 'CreditRating', 'Status', 'OnlineOrderFlag')
ORDER BY table_name, column_name;
GO