/*
  dim_date_checks.sql
  Design checks for dw.dim_date, the calendar shared by every fact:
  the full range of dates the facts will use (after the date shifts),
  the last data date of each module, and the company's fiscal year.

  Sources: AdventureWorks2025, AdventureWorksDW2025. Read-only.
  Shifts: HR +4,017 days, DW +4,170 days, other OLTP tables none.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- dim_date: which dates must the calendar cover?
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. First and last date of every date that a fact will link to dim_date.
SELECT 'fact_sales.order_date' AS fact_date,
       CAST(MIN(OrderDate) AS date) AS first_date, CAST(MAX(OrderDate) AS date) AS last_date
FROM Sales.SalesOrderHeader
UNION ALL
SELECT 'fact_sales.due_date',  CAST(MIN(DueDate) AS date),  CAST(MAX(DueDate) AS date)
FROM Sales.SalesOrderHeader
UNION ALL
SELECT 'fact_sales.ship_date', CAST(MIN(ShipDate) AS date), CAST(MAX(ShipDate) AS date)
FROM Sales.SalesOrderHeader
UNION ALL
SELECT 'fact_sales_quota.quota_date', CAST(MIN(QuotaDate) AS date), CAST(MAX(QuotaDate) AS date)
FROM Sales.SalesPersonQuotaHistory
UNION ALL
SELECT 'fact_purchase.order_date', CAST(MIN(OrderDate) AS date), CAST(MAX(OrderDate) AS date)
FROM Purchasing.PurchaseOrderHeader
UNION ALL
SELECT 'fact_purchase.ship_date',  CAST(MIN(ShipDate) AS date),  CAST(MAX(ShipDate) AS date)
FROM Purchasing.PurchaseOrderHeader
UNION ALL
SELECT 'fact_purchase.due_date',   CAST(MIN(DueDate) AS date),   CAST(MAX(DueDate) AS date)
FROM Purchasing.PurchaseOrderDetail
UNION ALL
SELECT 'fact_work_order.start_date', CAST(MIN(StartDate) AS date), CAST(MAX(StartDate) AS date)
FROM Production.WorkOrder
UNION ALL
SELECT 'fact_work_order.end_date',   CAST(MIN(EndDate) AS date),   CAST(MAX(EndDate) AS date)
FROM Production.WorkOrder
UNION ALL
SELECT 'fact_work_order.due_date',   CAST(MIN(DueDate) AS date),   CAST(MAX(DueDate) AS date)
FROM Production.WorkOrder
UNION ALL
SELECT 'fact_inventory_current.snapshot_date',
       CAST(MAX(ModifiedDate) AS date), CAST(MAX(ModifiedDate) AS date)
FROM Production.ProductInventory
UNION ALL
SELECT 'fact_finance.period_date (DW +4,170, month-end)',
       EOMONTH(DATEADD(day, 4170, MIN([Date]))), EOMONTH(DATEADD(day, 4170, MAX([Date])))
FROM AdventureWorksDW2025.dbo.FactFinance
UNION ALL
SELECT 'dim_employee.hire_date (HR +4,017)',
       DATEADD(day, 4017, MIN(HireDate)), DATEADD(day, 4017, MAX(HireDate))
FROM HumanResources.Employee
UNION ALL
SELECT 'HR department start (HR +4,017)',
       CAST(DATEADD(day, 4017, MIN(StartDate)) AS date), CAST(DATEADD(day, 4017, MAX(StartDate)) AS date)
FROM HumanResources.EmployeeDepartmentHistory
UNION ALL
SELECT 'HR pay change (HR +4,017)',
       CAST(DATEADD(day, 4017, MIN(RateChangeDate)) AS date), CAST(DATEADD(day, 4017, MAX(RateChangeDate)) AS date)
FROM HumanResources.EmployeePayHistory
ORDER BY first_date;
GO

-- =====================================================================
-- dim_date: does the company use a fiscal year that differs from the
-- calendar year? (The DW calendar holds the company's fiscal columns.)
-- =====================================================================

-- 2. Fiscal quarter and fiscal year offset for each calendar month.
SELECT  MonthNumberOfYear                         AS calendar_month,
        MIN(FiscalQuarter)                        AS fiscal_quarter,
        MIN(FiscalYear - CalendarYear)            AS fiscal_minus_calendar_year_min,
        MAX(FiscalYear - CalendarYear)            AS fiscal_minus_calendar_year_max
FROM AdventureWorksDW2025.dbo.DimDate
GROUP BY MonthNumberOfYear
ORDER BY MonthNumberOfYear;
GO
-- Results (03 Nov 2026):
--   1. Fact dates run from 2022-04-15 (first purchase order) to 2025-10-21
--      (last purchase due date). HR dates start 2017-06-29 (first hire).
--      Last data date differs by module: finance 2025-05-31, work orders
--      2025-06-16, sales orders 2025-06-29, inventory snapshot 2025-08-11,
--      purchase ship 2025-10-16.
--   2. Fiscal quarter 1 = July-September, 2 = October-December,
--      3 = January-March, 4 = April-June: the company's fiscal year starts
--      on 1 July. The DW's fiscal YEAR numbers are inconsistent (each month
--      shows two different offsets from the calendar year), so they are not
--      copied.
-- Decisions:
--   - dim_date covers whole years 2017-01-01 to 2025-12-31: every fact date
--     and every hire date, and complete years for time intelligence.
--   - No "unknown" row in dim_date: Power BI needs a gap-free, unique date
--     table. Rows with a missing date are caught by a data quality check
--     in the pipeline (none exist today).
--   - Fiscal columns derived from the rule "fiscal year starts 1 July,
--     named by the year it ends" (FY2025 = Jul 2024 - Jun 2025).
--     Calendar year is the default for YTD; fiscal YTD available on
--     finance pages.
--   - YTD and "latest" measures use each module's own last data date
--     (MAX of its fact dates), never today's date and never one shared date.
--   - Headcount snapshot month-ends: April 2022 (first operational month)
--     to October 2025 (last operational month).
--   - quota_period_start / quota_period_end from the 12 quota dates;
--     dates before 2022-05-30 or after 2025-05-27 = "No quota period".