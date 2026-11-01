/*
  03_fact_design_checks.sql
  Checks run before finalising each fact table design:
  grain uniqueness, measure consistency, and lookups the load will depend on.

  Read-only. Results are recorded in docs/design notes.
*/


-- =====================================================================
-- fact_sales: one row per sales order line
-- =====================================================================

USE AdventureWorks2025;
GO

-- Results (01 Nov 2026):
--   1. 121,317 lines, 121,317 distinct IDs. Grain confirmed.
--   2. 0 lines differ. LineTotal = UnitPrice x OrderQty x (1 - discount).
--   3. 0 orders differ. SUM(LineTotal) = SubTotal for every order.
--   4. All 102 period pairs: next period starts 1 day after previous EndDate
--      (EndDate is inclusive, so OrderDate <= EndDate is the right rule).
--   5. 121,253 lines match 1 cost period; 64 lines match 0 (no cost).
--   6. No missing or illogical dates. Every order ships in 7-8 days and
--      none after the due date.

-- 1. Grain: SalesOrderDetailID must be unique (one row = one order line).
SELECT  COUNT(*)                           AS order_lines,
        COUNT(DISTINCT SalesOrderDetailID) AS distinct_line_ids
FROM Sales.SalesOrderDetail;

-- 2. LineTotal should equal UnitPrice x OrderQty x (1 - UnitPriceDiscount).
SELECT  COUNT(*) AS lines_where_line_total_differs
FROM Sales.SalesOrderDetail
WHERE ABS(LineTotal - UnitPrice * OrderQty * (1 - UnitPriceDiscount)) > 0.01;

-- 3. Sum of line totals per order should equal the order SubTotal.
--    Revenue is defined as SUM(LineTotal), so this must reconcile.
SELECT  COUNT(*) AS orders_where_subtotal_differs
FROM Sales.SalesOrderHeader h
JOIN (
    SELECT SalesOrderID, SUM(LineTotal) AS sum_line_total
    FROM Sales.SalesOrderDetail
    GROUP BY SalesOrderID
) d ON d.SalesOrderID = h.SalesOrderID
WHERE ABS(h.SubTotal - d.sum_line_total) > 0.01;

-- 4. Cost history boundaries: does a new cost period start the day
--    after the previous one ends, on the same day, or with gaps?
SELECT  DATEDIFF(day, prev.EndDate, nxt.StartDate) AS days_between_periods,
        COUNT(*)                                  AS period_pairs
FROM Production.ProductCostHistory prev
JOIN Production.ProductCostHistory nxt
  ON nxt.ProductID = prev.ProductID
 AND nxt.StartDate = (SELECT MIN(x.StartDate)
                      FROM Production.ProductCostHistory x
                      WHERE x.ProductID = prev.ProductID
                        AND x.StartDate > prev.StartDate)
GROUP BY DATEDIFF(day, prev.EndDate, nxt.StartDate);

-- 5. Cost lookup coverage: how many cost periods match each order line
--    on its order date? Expect exactly 1 for every line.
SELECT  matches        AS cost_periods_matched,
        COUNT(*)       AS order_lines
FROM (
    SELECT  d.SalesOrderDetailID,
            COUNT(c.ProductID) AS matches
    FROM Sales.SalesOrderDetail d
    JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
    LEFT JOIN Production.ProductCostHistory c
           ON c.ProductID = d.ProductID
          AND h.OrderDate >= c.StartDate
          AND (c.EndDate IS NULL OR h.OrderDate <= c.EndDate)
    GROUP BY d.SalesOrderDetailID
) m
GROUP BY matches
ORDER BY matches;

-- 6. Dates needed for shipping KPIs: any missing or out of order?
SELECT  SUM(CASE WHEN ShipDate IS NULL        THEN 1 ELSE 0 END) AS missing_ship_date,
        SUM(CASE WHEN ShipDate < OrderDate     THEN 1 ELSE 0 END) AS shipped_before_order,
        SUM(CASE WHEN DueDate  < OrderDate     THEN 1 ELSE 0 END) AS due_before_order,
        SUM(CASE WHEN ShipDate > DueDate       THEN 1 ELSE 0 END) AS shipped_after_due,
        MIN(DATEDIFF(day, OrderDate, ShipDate)) AS min_days_to_ship,
        MAX(DATEDIFF(day, OrderDate, ShipDate)) AS max_days_to_ship
FROM Sales.SalesOrderHeader;
GO


-- =====================================================================
-- fact_sales: investigate the 64 order lines with no cost period
-- =====================================================================

-- Result (01 Nov 2026): 25 products. Every no-cost line was ordered
-- AFTER the product's last cost period ended (all end 28 May 2024;
-- orders 29 May 2024 to 29 Apr 2025). No line is before its first period.

-- Which products, which dates, and how do they relate to the
-- product's cost periods?
WITH no_cost AS (
    SELECT  d.SalesOrderDetailID, d.ProductID, h.OrderDate
    FROM Sales.SalesOrderDetail d
    JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
    WHERE NOT EXISTS (
        SELECT 1 FROM Production.ProductCostHistory c
        WHERE c.ProductID = d.ProductID
          AND h.OrderDate >= c.StartDate
          AND (c.EndDate IS NULL OR h.OrderDate <= c.EndDate))
)
SELECT  n.ProductID,
        p.Name,
        p.StandardCost,
        COUNT(*)                                     AS lines,
        CAST(MIN(n.OrderDate) AS date)               AS first_order,
        CAST(MAX(n.OrderDate) AS date)               AS last_order,
        (SELECT COUNT(*) FROM Production.ProductCostHistory c
          WHERE c.ProductID = n.ProductID)           AS cost_periods,
        (SELECT CAST(MIN(c.StartDate) AS date) FROM Production.ProductCostHistory c
          WHERE c.ProductID = n.ProductID)           AS first_cost_start,
        (SELECT CAST(MAX(c.EndDate) AS date) FROM Production.ProductCostHistory c
          WHERE c.ProductID = n.ProductID)           AS last_cost_end
FROM no_cost n
JOIN Production.Product p ON p.ProductID = n.ProductID
GROUP BY n.ProductID, p.Name, p.StandardCost
ORDER BY lines DESC;

-- Result (01 Nov 2026): 23 orders with a DW gap, 64 lines missing,
-- 23 orders with no-cost lines, 23 match exactly. The DW dropped exactly
-- the lines that had no cost period. Closes the 64-line open item.

-- Are these the same 64 lines that are missing from the DW sales tables
-- (OLTP 121,317 lines vs DW 121,253)? Compare line counts per order.
WITH oltp AS (
    SELECT h.SalesOrderNumber, COUNT(*) AS oltp_lines
    FROM Sales.SalesOrderDetail d
    JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
    GROUP BY h.SalesOrderNumber
),
dw AS (
    SELECT SalesOrderNumber, COUNT(*) AS dw_lines
    FROM (SELECT SalesOrderNumber FROM AdventureWorksDW2025.dbo.FactInternetSales
          UNION ALL
          SELECT SalesOrderNumber FROM AdventureWorksDW2025.dbo.FactResellerSales) x
    GROUP BY SalesOrderNumber
),
gap AS (
    SELECT o.SalesOrderNumber, o.oltp_lines - ISNULL(w.dw_lines, 0) AS missing_in_dw
    FROM oltp o
    LEFT JOIN dw w ON w.SalesOrderNumber = o.SalesOrderNumber
    WHERE o.oltp_lines <> ISNULL(w.dw_lines, 0)
),
no_cost_orders AS (
    SELECT h.SalesOrderNumber, COUNT(*) AS no_cost_lines
    FROM Sales.SalesOrderDetail d
    JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
    WHERE NOT EXISTS (
        SELECT 1 FROM Production.ProductCostHistory c
        WHERE c.ProductID = d.ProductID
          AND h.OrderDate >= c.StartDate
          AND (c.EndDate IS NULL OR h.OrderDate <= c.EndDate))
    GROUP BY h.SalesOrderNumber
)
SELECT  (SELECT COUNT(*)           FROM gap)            AS orders_with_dw_gap,
        (SELECT SUM(missing_in_dw) FROM gap)            AS lines_missing_in_dw,
        (SELECT COUNT(*)           FROM no_cost_orders) AS orders_with_no_cost_lines,
        (SELECT COUNT(*) FROM gap g
           JOIN no_cost_orders n ON n.SalesOrderNumber = g.SalesOrderNumber
          WHERE g.missing_in_dw = n.no_cost_lines)      AS orders_matching_exactly;
GO


-- =====================================================================
-- fact_sales: test the proposed cost rule
-- =====================================================================

-- Rule: use the latest cost period that started on or before the order
-- date. For the 25 products, the latest period should hold the same
-- cost as Product.StandardCost (the current cost). Expect 0 rows.
WITH latest AS (
    SELECT  c.ProductID, c.StandardCost,
            ROW_NUMBER() OVER (PARTITION BY c.ProductID ORDER BY c.StartDate DESC) AS rn
    FROM Production.ProductCostHistory c
)
SELECT  p.ProductID, p.Name,
        l.StandardCost AS latest_period_cost,
        p.StandardCost AS product_standard_cost
FROM latest l
JOIN Production.Product p ON p.ProductID = l.ProductID
WHERE l.rn = 1
  AND ABS(l.StandardCost - p.StandardCost) > 0.0001;
GO


-- =====================================================================
-- fact_sales_quota: one row per salesperson per quota period (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- Results (01 Nov 2026):
--   1. 163 rows = 163 distinct salesperson + date pairs, 17 salespeople.
--   2. Always 3 months between quotas. Quota dates fall on 28 Feb and
--      29 or 30 May, Aug and Nov (not calendar quarters).
--   3. 3 months AFTER QuotaDate: ratio 0.860, 0 quotas with zero sales.
--      3 months BEFORE: ratio 0.809, 4 with zero sales.
--      Decision: a quota covers the 3 months starting on QuotaDate.
--   4. 275, 277, 282 changed territory (2 periods each).
--      274, 285, 287 have no territory.
--   5. 0 sellers without quota, 0 quota holders without orders.

-- 1. Grain: one row per salesperson per QuotaDate?
SELECT  COUNT(*)                                                AS quota_rows,
        COUNT(DISTINCT CONCAT(BusinessEntityID, '|', QuotaDate)) AS distinct_person_dates,
        COUNT(DISTINCT BusinessEntityID)                        AS salespeople
FROM Sales.SalesPersonQuotaHistory;

-- 2. How often are quotas set, and on which days?
WITH q AS (
    SELECT  BusinessEntityID, QuotaDate,
            LEAD(QuotaDate) OVER (PARTITION BY BusinessEntityID ORDER BY QuotaDate) AS next_quota_date
    FROM Sales.SalesPersonQuotaHistory
)
SELECT  DATEDIFF(month, QuotaDate, next_quota_date) AS months_to_next_quota,
        COUNT(*)                                    AS quota_pairs
FROM q
WHERE next_quota_date IS NOT NULL
GROUP BY DATEDIFF(month, QuotaDate, next_quota_date);

SELECT  MONTH(QuotaDate) AS quota_month,
        DAY(QuotaDate)   AS quota_day,
        COUNT(*)         AS quota_rows
FROM Sales.SalesPersonQuotaHistory
GROUP BY MONTH(QuotaDate), DAY(QuotaDate)
ORDER BY quota_month, quota_day;

-- 3. What period does a quota cover? Compare each quota with the
--    salesperson's actual sales in the 3 months AFTER QuotaDate and in
--    the 3 months BEFORE it. The matching period should give a ratio
--    near 1 and few quotas with zero actual sales.
WITH q AS (
    SELECT  qh.BusinessEntityID, qh.QuotaDate, qh.SalesQuota,
            (SELECT ISNULL(SUM(h.SubTotal), 0) FROM Sales.SalesOrderHeader h
              WHERE h.SalesPersonID = qh.BusinessEntityID
                AND h.OrderDate >= qh.QuotaDate
                AND h.OrderDate <  DATEADD(month, 3, qh.QuotaDate)) AS actual_after,
            (SELECT ISNULL(SUM(h.SubTotal), 0) FROM Sales.SalesOrderHeader h
              WHERE h.SalesPersonID = qh.BusinessEntityID
                AND h.OrderDate >  DATEADD(month, -3, qh.QuotaDate)
                AND h.OrderDate <= qh.QuotaDate)                    AS actual_before
    FROM Sales.SalesPersonQuotaHistory qh
)
SELECT  'quota covers 3 months after QuotaDate' AS assumption,
        CAST(SUM(actual_after) / SUM(SalesQuota) AS decimal(10,3)) AS actual_to_quota_ratio,
        SUM(CASE WHEN actual_after = 0 THEN 1 ELSE 0 END)          AS quotas_with_zero_actual
FROM q
UNION ALL
SELECT  'quota covers 3 months before QuotaDate',
        CAST(SUM(actual_before) / SUM(SalesQuota) AS decimal(10,3)),
        SUM(CASE WHEN actual_before = 0 THEN 1 ELSE 0 END)
FROM q;

-- 4. Territory of each salesperson: who changed territory, who has none?
SELECT  s.BusinessEntityID,
        COUNT(t.TerritoryID)              AS territory_periods,
        CAST(MIN(t.StartDate) AS date)    AS first_start,
        CAST(MAX(t.EndDate)   AS date)    AS last_end
FROM Sales.SalesPerson s
LEFT JOIN Sales.SalesTerritoryHistory t ON t.BusinessEntityID = s.BusinessEntityID
GROUP BY s.BusinessEntityID
HAVING COUNT(t.TerritoryID) <> 1
ORDER BY s.BusinessEntityID;

-- 5. Salespeople who have orders but no quota, and quotas with no orders.
SELECT  (SELECT COUNT(DISTINCT h.SalesPersonID) FROM Sales.SalesOrderHeader h
          WHERE h.SalesPersonID IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM Sales.SalesPersonQuotaHistory q
                            WHERE q.BusinessEntityID = h.SalesPersonID)) AS sellers_without_quota,
        (SELECT COUNT(DISTINCT q.BusinessEntityID) FROM Sales.SalesPersonQuotaHistory q
          WHERE NOT EXISTS (SELECT 1 FROM Sales.SalesOrderHeader h
                            WHERE h.SalesPersonID = q.BusinessEntityID))  AS quota_holders_without_orders;
GO


-- =====================================================================
-- fact_sales_quota: quota calendar and territory assignment
-- =====================================================================

-- Results (01 Nov 2026):
--   A. 12 quota dates, 3 months apart, shared by all active salespeople
--      (2022-05-30 to 2025-02-28). One company-wide quota calendar.
--      Last period ends 2025-05-27; sales continue to 2025-06-29.
--   B. 132 quota rows match 1 territory period; 7 match none.
--   C. 274 sells only in North America, 285 only in Pacific (Australia),
--      287 in Europe. Likely regional sales managers.

-- A. Is there one company-wide quota calendar? List every quota date
--    and how many salespeople got a quota on it.
SELECT  CAST(QuotaDate AS date) AS quota_date,
        COUNT(*)                AS salespeople
FROM Sales.SalesPersonQuotaHistory
GROUP BY QuotaDate
ORDER BY QuotaDate;

-- B. Territory lookup: for salespeople with territory history, how many
--    territory periods cover each quota date? Expect exactly 1.
SELECT  matches  AS territory_periods_matched,
        COUNT(*) AS quota_rows
FROM (
    SELECT  q.BusinessEntityID, q.QuotaDate,
            COUNT(t.TerritoryID) AS matches
    FROM Sales.SalesPersonQuotaHistory q
    LEFT JOIN Sales.SalesTerritoryHistory t
           ON t.BusinessEntityID = q.BusinessEntityID
          AND q.QuotaDate >= t.StartDate
          AND (t.EndDate IS NULL OR q.QuotaDate <= t.EndDate)
    WHERE q.BusinessEntityID NOT IN (274, 285, 287)
    GROUP BY q.BusinessEntityID, q.QuotaDate
) m
GROUP BY matches;

-- C. The 3 salespeople without territory: where do their orders come from?
SELECT  h.SalesPersonID,
        t.[Group]  AS territory_group,
        t.Name     AS territory,
        COUNT(*)   AS orders
FROM Sales.SalesOrderHeader h
JOIN Sales.SalesTerritory t ON t.TerritoryID = h.TerritoryID
WHERE h.SalesPersonID IN (274, 285, 287)
GROUP BY h.SalesPersonID, t.[Group], t.Name
ORDER BY h.SalesPersonID, orders DESC;
GO


-- =====================================================================
-- fact_sales_quota: the 7 quota rows with no territory period
-- =====================================================================

-- Show each unmatched quota row next to all territory periods of that
-- salesperson, to see if it falls in a gap, before the first period,
-- or after the last one.
WITH unmatched AS (
    SELECT  q.BusinessEntityID, q.QuotaDate
    FROM Sales.SalesPersonQuotaHistory q
    WHERE q.BusinessEntityID NOT IN (274, 285, 287)
      AND NOT EXISTS (
          SELECT 1 FROM Sales.SalesTerritoryHistory t
          WHERE t.BusinessEntityID = q.BusinessEntityID
            AND q.QuotaDate >= t.StartDate
            AND (t.EndDate IS NULL OR q.QuotaDate <= t.EndDate))
)
SELECT  u.BusinessEntityID,
        CAST(u.QuotaDate   AS date) AS quota_date,
        t.TerritoryID,
        CAST(t.StartDate   AS date) AS territory_start,
        CAST(t.EndDate     AS date) AS territory_end
FROM unmatched u
LEFT JOIN Sales.SalesTerritoryHistory t ON t.BusinessEntityID = u.BusinessEntityID
ORDER BY u.BusinessEntityID, u.QuotaDate, t.StartDate;

-- Region groups of all orders by the 3 salespeople without territory.
SELECT  h.SalesPersonID,
        t.[Group] AS territory_group,
        COUNT(*)  AS orders
FROM Sales.SalesOrderHeader h
JOIN Sales.SalesTerritory t ON t.TerritoryID = h.TerritoryID
WHERE h.SalesPersonID IN (274, 285, 287)
GROUP BY h.SalesPersonID, t.[Group]
ORDER BY h.SalesPersonID;
GO

-- Results (01 Nov 2026): 7 unmatched quota rows.
--   284: 1 row, quota 2023-08-30 before territory start 2023-09-30
--        (same source anomaly as the quota before hire).
--   280: 6 rows, 2023-11-30 to 2025-02-28. Left Northwest (territory 1)
--        on 2023-09-29; 284 took Northwest on 2023-09-30.
--   Orders by region group: 274 North America 48, 285 Pacific 16,
--   287 Europe 39. These three are regional sales managers.

-- Where did 280 and 284 sell, and when?
SELECT  h.SalesPersonID,
        t.Name                         AS territory,
        CAST(MIN(h.OrderDate) AS date) AS first_order,
        CAST(MAX(h.OrderDate) AS date) AS last_order,
        COUNT(*)                       AS orders
FROM Sales.SalesOrderHeader h
JOIN Sales.SalesTerritory t ON t.TerritoryID = h.TerritoryID
WHERE h.SalesPersonID IN (280, 284)
GROUP BY h.SalesPersonID, t.Name
ORDER BY h.SalesPersonID, first_order;
GO