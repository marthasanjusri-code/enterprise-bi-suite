/*
  fact_inventory_daily_checks.sql
  Design checks for dw.fact_inventory_daily (one row per product per day,
  from the DW snapshot): grain, daily density, balance consistency,
  product mapping to OLTP, unit cost, and agreement with current stock.

  Source: AdventureWorksDW2025 (compared with AdventureWorks2025). Read-only.
  DW dates are shifted +4,170 days to the OLTP timeline.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- fact_inventory_daily: one row per product per day (draft)
-- =====================================================================

USE AdventureWorksDW2025;
GO

-- 1. Grain: product + date unique? Size and shifted date range.
SELECT  COUNT(*)                                             AS snapshot_rows,
        COUNT(DISTINCT CONCAT(ProductKey, '|', DateKey))     AS distinct_product_days,
        COUNT(DISTINCT ProductKey)                           AS dw_products,
        COUNT(DISTINCT MovementDate)                         AS distinct_dates,
        CAST(DATEADD(day, 4170, MIN(MovementDate)) AS date)  AS first_shifted_date,
        CAST(DATEADD(day, 4170, MAX(MovementDate)) AS date)  AS last_shifted_date
FROM dbo.FactProductInventory;

-- 2. Density: does each product have a row on EVERY day between its first
--    and last date, or only on days with movement? This decides how the
--    closing-balance measure must work.
WITH p AS (
    SELECT  ProductKey,
            MIN(MovementDate) AS first_date,
            MAX(MovementDate) AS last_date,
            COUNT(*)          AS rows_present
    FROM dbo.FactProductInventory
    GROUP BY ProductKey
)
SELECT  COUNT(*)                                                         AS products,
        SUM(rows_present)                                                AS rows_present,
        SUM(DATEDIFF(day, first_date, last_date) + 1)                    AS rows_if_daily,
        SUM(CASE WHEN rows_present < DATEDIFF(day, first_date, last_date) + 1
                 THEN 1 ELSE 0 END)                                      AS products_with_gaps,
        COUNT(DISTINCT first_date)                                       AS distinct_first_dates,
        COUNT(DISTINCT last_date)                                        AS distinct_last_dates
FROM p;

-- 3. Balance consistency: today's balance = yesterday's balance + in - out?
WITH x AS (
    SELECT  ProductKey, MovementDate, UnitsIn, UnitsOut, UnitsBalance,
            LAG(UnitsBalance) OVER (PARTITION BY ProductKey ORDER BY MovementDate) AS prev_balance
    FROM dbo.FactProductInventory
)
SELECT  COUNT(*)                                                                   AS rows_checked,
        SUM(CASE WHEN UnitsBalance <> prev_balance + UnitsIn - UnitsOut THEN 1 ELSE 0 END) AS balance_breaks,
        SUM(CASE WHEN UnitsBalance < 0 THEN 1 ELSE 0 END)                          AS negative_balances
FROM x
WHERE prev_balance IS NOT NULL;

-- 4. Mapping to OLTP products: several DW product keys (old versions) map
--    to one ProductNumber. Do two keys of the same product ever have a
--    row on the same day? If yes, mapping would double count stock.
WITH m AS (
    SELECT  f.DateKey,
            dp.ProductAlternateKey,
            COUNT(*) AS dw_rows
    FROM dbo.FactProductInventory f
    JOIN dbo.DimProduct dp ON dp.ProductKey = f.ProductKey
    GROUP BY f.DateKey, dp.ProductAlternateKey
)
SELECT  COUNT(*)                                        AS product_days,
        SUM(CASE WHEN dw_rows > 1 THEN 1 ELSE 0 END)    AS product_days_with_two_keys
FROM m;

-- 5. Unit cost: missing, zero, or changing over time?
SELECT  SUM(CASE WHEN UnitCost IS NULL THEN 1 ELSE 0 END) AS rows_cost_null,
        SUM(CASE WHEN UnitCost = 0     THEN 1 ELSE 0 END) AS rows_cost_zero,
        (SELECT COUNT(*) FROM (
            SELECT ProductKey FROM dbo.FactProductInventory
            GROUP BY ProductKey HAVING COUNT(DISTINCT UnitCost) > 1) c) AS products_with_cost_changes
FROM dbo.FactProductInventory;

-- 6. Agreement with current stock: on the date that shifts to 2025-08-11
--    (the OLTP snapshot date), compare each product's DW balance (latest
--    row on or before that date) with OLTP on-hand stock (all locations).
WITH dw_latest AS (
    SELECT  dp.ProductAlternateKey AS product_number,
            f.UnitsBalance,
            ROW_NUMBER() OVER (PARTITION BY f.ProductKey ORDER BY f.MovementDate DESC) AS rn
    FROM dbo.FactProductInventory f
    JOIN dbo.DimProduct dp ON dp.ProductKey = f.ProductKey
    WHERE f.MovementDate <= DATEADD(day, -4170, CAST('2025-08-11' AS date))
),
dw AS (
    SELECT product_number, SUM(UnitsBalance) AS dw_balance
    FROM dw_latest WHERE rn = 1
    GROUP BY product_number
),
oltp AS (
    SELECT  p.ProductNumber AS product_number, SUM(i.Quantity) AS oltp_on_hand
    FROM AdventureWorks2025.Production.ProductInventory i
    JOIN AdventureWorks2025.Production.Product p ON p.ProductID = i.ProductID
    GROUP BY p.ProductNumber
)
SELECT  CAST(DATEADD(day, -4170, CAST('2025-08-11' AS date)) AS date)        AS dw_compare_date,
        COUNT(*)                                                             AS products_compared,
        SUM(CASE WHEN dw.product_number IS NOT NULL
                  AND o.product_number IS NOT NULL THEN 1 ELSE 0 END)        AS in_both,
        SUM(CASE WHEN o.product_number IS NULL THEN 1 ELSE 0 END)            AS only_in_dw,
        SUM(CASE WHEN dw.product_number IS NULL THEN 1 ELSE 0 END)           AS only_in_oltp,
        SUM(CASE WHEN dw.dw_balance = o.oltp_on_hand THEN 1 ELSE 0 END)      AS equal_quantity,
        SUM(CAST(dw.dw_balance AS bigint))                                   AS dw_total_units,
        SUM(CAST(o.oltp_on_hand AS bigint))                                  AS oltp_total_units
FROM dw
FULL OUTER JOIN oltp o ON o.product_number = dw.product_number;
GO
-- Results (03 Nov 2026):
--   1. 776,286 rows, all product + day pairs unique. 606 DW product keys,
--      1,281 days, shifted 2022-05-29 to 2025-11-29.
--   2. Fully dense: every product key has a row on every day
--      (606 x 1,281 = 776,286), all keys share the same first and last date.
--   3. Balance = previous + in - out on all 775,680 rows checked, but
--      3,319 rows have a NEGATIVE balance.
--   4. 98,637 of 645,624 product-days have two DW keys (old and new product
--      versions) on the same day: mapping by product number would double
--      count unless one version is chosen per day.
--   5. Unit cost never null or zero; it changes over time for all 606 keys.
--   6. On 2014-03-12 (= 2025-08-11 shifted): 432 products in both sources,
--      72 only in the DW, 0 only in OLTP. Equal quantity for 0 products.
--      DW total 258,981 units vs OLTP on hand 335,974.
--      The disagreement is real, not caused by check 4: products with only
--      one DW key also never match.
-- Decision: the two inventory sources do not agree on any product, so only
-- one is used (agreed rule from the bus matrix). fact_inventory_current
-- (OLTP) is kept: it has locations, matches the stock limits and shares the
-- OLTP timeline with sales, purchasing and production. fact_inventory_daily
-- is NOT built. P5 (stock trend, Should) moves to the open items: it could
-- later be rebuilt from OLTP TransactionHistory so it agrees with current
-- stock by construction.