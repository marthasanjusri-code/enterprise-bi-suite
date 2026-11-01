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

-- =====================================================================
-- HR dates and employee status
-- =====================================================================

USE AdventureWorks2025;
GO

SELECT  MIN(HireDate)                                   AS first_hire,
        MAX(HireDate)                                   AS last_hire,
        COUNT(*)                                        AS employees,
        SUM(CASE WHEN CurrentFlag = 1 THEN 1 ELSE 0 END) AS current_employees
FROM HumanResources.Employee;

SELECT  MIN(StartDate)                                  AS first_dept_start,
        MAX(StartDate)                                  AS last_dept_start,
        COUNT(EndDate)                                  AS rows_with_end_date
FROM HumanResources.EmployeeDepartmentHistory;

SELECT  MIN(RateChangeDate) AS first_rate_change,
        MAX(RateChangeDate) AS last_rate_change
FROM HumanResources.EmployeePayHistory;

-- Latest stock snapshot date per source, for the two inventory facts
SELECT  MAX(ModifiedDate) AS oltp_inventory_last_modified
FROM Production.ProductInventory;
GO

-- =====================================================================
-- Timeline audit: which tables were moved to 2022-2025?
-- =====================================================================

-- Sales were shifted to 2022-2025; HR was not. Check every date we use.
USE AdventureWorks2025;
GO

SELECT 'Sales.SalesOrderHeader.OrderDate' AS date_column,
       CAST(MIN(OrderDate) AS date) AS first_date, CAST(MAX(OrderDate) AS date) AS last_date
FROM Sales.SalesOrderHeader
UNION ALL
SELECT 'Sales.SalesPersonQuotaHistory.QuotaDate', CAST(MIN(QuotaDate) AS date), CAST(MAX(QuotaDate) AS date)
FROM Sales.SalesPersonQuotaHistory
UNION ALL
SELECT 'Sales.SalesTerritoryHistory.StartDate', CAST(MIN(StartDate) AS date), CAST(MAX(StartDate) AS date)
FROM Sales.SalesTerritoryHistory
UNION ALL
SELECT 'Sales.SpecialOffer.StartDate', CAST(MIN(StartDate) AS date), CAST(MAX(StartDate) AS date)
FROM Sales.SpecialOffer
UNION ALL
SELECT 'Purchasing.PurchaseOrderHeader.OrderDate', CAST(MIN(OrderDate) AS date), CAST(MAX(OrderDate) AS date)
FROM Purchasing.PurchaseOrderHeader
UNION ALL
SELECT 'Production.WorkOrder.StartDate', CAST(MIN(StartDate) AS date), CAST(MAX(StartDate) AS date)
FROM Production.WorkOrder
UNION ALL
SELECT 'Production.ProductCostHistory.StartDate', CAST(MIN(StartDate) AS date), CAST(MAX(StartDate) AS date)
FROM Production.ProductCostHistory
UNION ALL
SELECT 'Production.Product.SellStartDate', CAST(MIN(SellStartDate) AS date), CAST(MAX(SellStartDate) AS date)
FROM Production.Product
UNION ALL
SELECT 'Production.TransactionHistory.TransactionDate', CAST(MIN(TransactionDate) AS date), CAST(MAX(TransactionDate) AS date)
FROM Production.TransactionHistory
UNION ALL
SELECT 'HumanResources.Employee.HireDate', MIN(HireDate), MAX(HireDate)
FROM HumanResources.Employee
UNION ALL
SELECT 'HumanResources.Employee.BirthDate', MIN(BirthDate), MAX(BirthDate)
FROM HumanResources.Employee
ORDER BY first_date;
GO

-- Is OLTP HR on the same old timeline as the DW? Compare hire dates
-- for the same employee (matched by LoginID). One single offset of 0
-- means HR needs the same +4,170 day shift as the DW tables.
SELECT  DATEDIFF(day, d.HireDate, e.HireDate) AS day_offset,
        COUNT(*)                              AS employees
FROM AdventureWorks2025.HumanResources.Employee e
JOIN AdventureWorksDW2025.dbo.DimEmployee d
  ON d.LoginID = e.LoginID
 AND d.CurrentFlag = 1
GROUP BY DATEDIFF(day, d.HireDate, e.HireDate);
GO

-- =====================================================================
-- Test: HR shift of +4,017 days (DW->sales 4,170 minus DW->HR 153)
-- =====================================================================

USE AdventureWorks2025;
GO

-- Test 1: after the shift, every salesperson should be hired
-- on or before their first territory, first quota and first order.
SELECT  s.BusinessEntityID,
        DATEADD(day, 4017, e.HireDate) AS shifted_hire_date,
        (SELECT MIN(t.StartDate) FROM Sales.SalesTerritoryHistory t
          WHERE t.BusinessEntityID = s.BusinessEntityID)             AS first_territory_start,
        (SELECT MIN(q.QuotaDate) FROM Sales.SalesPersonQuotaHistory q
          WHERE q.BusinessEntityID = s.BusinessEntityID)             AS first_quota,
        (SELECT MIN(h.OrderDate) FROM Sales.SalesOrderHeader h
          WHERE h.SalesPersonID = s.BusinessEntityID)                AS first_order
FROM Sales.SalesPerson s
JOIN HumanResources.Employee e ON e.BusinessEntityID = s.BusinessEntityID
ORDER BY shifted_hire_date;

-- Test 2: age at hire, with and without shifting BirthDate.
SELECT  'shift hire only'        AS option_name,
        MIN(DATEDIFF(year, BirthDate, DATEADD(day, 4017, HireDate))) AS min_age_at_hire,
        MAX(DATEDIFF(year, BirthDate, DATEADD(day, 4017, HireDate))) AS max_age_at_hire,
        MIN(DATEDIFF(year, BirthDate, '2025-06-29'))                 AS min_age_at_data_end,
        MAX(DATEDIFF(year, BirthDate, '2025-06-29'))                 AS max_age_at_data_end
FROM HumanResources.Employee
UNION ALL
SELECT  'shift hire and birth',
        MIN(DATEDIFF(year, BirthDate, HireDate)),
        MAX(DATEDIFF(year, BirthDate, HireDate)),
        MIN(DATEDIFF(year, DATEADD(day, 4017, BirthDate), '2025-06-29')),
        MAX(DATEDIFF(year, DATEADD(day, 4017, BirthDate), '2025-06-29'))
FROM HumanResources.Employee;
GO

-- Result (01 Nov 2026): Test 1: 16 of 17 salespeople hired on or before
-- their first territory, quota and order. 11 match to the exact day.
-- Exception: salesperson 284, first quota one month before hire.
-- Test 2: shifting hire and birth gives ages 18-60 at hire, 23-63 at data end.
-- Decision: shift all HR dates, including BirthDate, by +4,017 days.

-- Confirm the salesperson 284 anomaly exists in the original DW data
-- (DW EmployeeKey 293). Both dates move by the same offset, so the
-- order cannot be caused by our shift.
-- Result (01 Nov 2026): 1 row, hire 2012-04-30, first quota 2012-03-30.
-- Anomaly is in the source. Kept as is and documented.
SELECT  d.EmployeeKey,
        d.HireDate,
        MIN(q.[Date]) AS first_quota
FROM AdventureWorksDW2025.dbo.DimEmployee d
JOIN AdventureWorksDW2025.dbo.FactSalesQuota q ON q.EmployeeKey = d.EmployeeKey
GROUP BY d.EmployeeKey, d.HireDate
HAVING MIN(q.[Date]) < d.HireDate;
GO