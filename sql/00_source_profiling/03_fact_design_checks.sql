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