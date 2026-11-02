/*
  fact_work_order_checks.sql
  Design checks for dw.fact_work_order (one row per work order):
  grain, quantity consistency, scrap reasons, dates, products made,
  and the cost lookup needed to value scrap.

  Source: AdventureWorks2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- fact_work_order: one row per work order (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. Grain: WorkOrderID unique?
SELECT  COUNT(*)                    AS work_orders,
        COUNT(DISTINCT WorkOrderID) AS distinct_ids,
        COUNT(DISTINCT ProductID)   AS products
FROM Production.WorkOrder;

-- 2. Quantities: does stocked + scrapped = ordered? Is a scrap reason
--    given exactly when something was scrapped?
SELECT  SUM(CASE WHEN StockedQty + ScrappedQty <> OrderQty      THEN 1 ELSE 0 END) AS qty_not_adding_up,
        SUM(CASE WHEN ScrappedQty > 0                           THEN 1 ELSE 0 END) AS orders_with_scrap,
        SUM(CASE WHEN ScrappedQty > 0 AND ScrapReasonID IS NULL THEN 1 ELSE 0 END) AS scrap_without_reason,
        SUM(CASE WHEN ScrappedQty = 0 AND ScrapReasonID IS NOT NULL THEN 1 ELSE 0 END) AS reason_without_scrap,
        SUM(OrderQty)    AS ordered_qty,
        SUM(ScrappedQty) AS scrapped_qty
FROM Production.WorkOrder;

-- 3. Scrap reasons: is there enough variety for a "scrap by reason" chart?
SELECT  r.Name           AS scrap_reason,
        COUNT(*)         AS work_orders,
        SUM(w.ScrappedQty) AS scrapped_qty
FROM Production.WorkOrder w
JOIN Production.ScrapReason r ON r.ScrapReasonID = w.ScrapReasonID
GROUP BY r.Name
ORDER BY scrapped_qty DESC;

-- 4. Dates: open orders, impossible orders, late orders, duration.
SELECT  SUM(CASE WHEN EndDate IS NULL    THEN 1 ELSE 0 END) AS open_work_orders,
        SUM(CASE WHEN EndDate < StartDate THEN 1 ELSE 0 END) AS ended_before_start,
        SUM(CASE WHEN DueDate < StartDate THEN 1 ELSE 0 END) AS due_before_start,
        SUM(CASE WHEN EndDate > DueDate   THEN 1 ELSE 0 END) AS finished_after_due,
        MIN(DATEDIFF(day, StartDate, EndDate)) AS min_days_to_finish,
        MAX(DATEDIFF(day, StartDate, EndDate)) AS max_days_to_finish,
        MIN(DATEDIFF(day, StartDate, DueDate)) AS min_days_to_due,
        MAX(DATEDIFF(day, StartDate, DueDate)) AS max_days_to_due,
        CAST(MAX(EndDate) AS date)             AS last_end_date
FROM Production.WorkOrder;

-- 5. Products made: are they all flagged as made in-house (MakeFlag = 1)?
SELECT  p.MakeFlag,
        p.FinishedGoodsFlag,
        COUNT(DISTINCT w.ProductID) AS products,
        COUNT(*)                    AS work_orders
FROM Production.WorkOrder w
JOIN Production.Product p ON p.ProductID = w.ProductID
GROUP BY p.MakeFlag, p.FinishedGoodsFlag;

-- 6. Scrap cost needs product cost on the start date. How many cost
--    periods match each work order? Expect exactly 1.
SELECT  matches  AS cost_periods_matched,
        COUNT(*) AS work_orders,
        SUM(scrapped_qty) AS scrapped_qty
FROM (
    SELECT  w.WorkOrderID,
            w.ScrappedQty AS scrapped_qty,
            COUNT(c.ProductID) AS matches
    FROM Production.WorkOrder w
    LEFT JOIN Production.ProductCostHistory c
           ON c.ProductID = w.ProductID
          AND w.StartDate >= c.StartDate
          AND (c.EndDate IS NULL OR w.StartDate <= c.EndDate)
    GROUP BY w.WorkOrderID, w.ScrappedQty
) m
GROUP BY matches
ORDER BY matches;
GO
-- Results (02 Nov 2026):
--   1. 72,591 work orders, all IDs unique, 238 products. Grain confirmed.
--   2. Stocked + scrapped = ordered on every order. 729 orders have scrap
--      (10,651 of 4,507,721 units, about 0.24%). Reason given exactly when
--      scrap exists.
--   3. 16 scrap reasons, 32 to 63 orders each. Good variety.
--   4. No open orders, no impossible dates. 22,790 orders (31.4%) finished
--      after due. Days to finish 10-32; due date is ALWAYS start + 11 days.
--      Production on-time % varies: P7 is a real KPI. Last end 2025-06-16.
--   5. All products MakeFlag = 1: 211 finished goods (49,541 orders) and
--      27 components (23,050 orders).
--   6. Cost lookup: 35,297 orders match 1 cost period, 37,294 match NONE,
--      and those hold 9,457 of the 10,651 scrapped units (89%).


-- =====================================================================
-- fact_work_order: why do half the work orders have no cost period?
-- =====================================================================

-- Classify each unmatched work order: product has no cost history at
-- all, started before the first period, or started after the last one.
WITH cost AS (
    SELECT  ProductID,
            COUNT(*)                                     AS periods,
            MIN(StartDate)                               AS first_start,
            MAX(ISNULL(EndDate, '9999-12-31'))           AS last_end
    FROM Production.ProductCostHistory
    GROUP BY ProductID
),
unmatched AS (
    SELECT  w.WorkOrderID, w.ProductID, w.StartDate, w.ScrappedQty
    FROM Production.WorkOrder w
    WHERE NOT EXISTS (
        SELECT 1 FROM Production.ProductCostHistory c
        WHERE c.ProductID = w.ProductID
          AND w.StartDate >= c.StartDate
          AND (c.EndDate IS NULL OR w.StartDate <= c.EndDate))
)
SELECT  CASE WHEN c.ProductID IS NULL       THEN 'no cost history'
             WHEN u.StartDate < c.first_start THEN 'before first period'
             WHEN u.StartDate > c.last_end    THEN 'after last period'
             ELSE                                  'in a gap'
        END                                              AS reason,
        p.FinishedGoodsFlag,
        COUNT(*)                                         AS work_orders,
        COUNT(DISTINCT u.ProductID)                      AS products,
        SUM(u.ScrappedQty)                               AS scrapped_qty,
        COUNT(DISTINCT CASE WHEN p.StandardCost = 0 THEN u.ProductID END) AS products_with_zero_standard_cost
FROM unmatched u
JOIN Production.Product p ON p.ProductID = u.ProductID
LEFT JOIN cost c          ON c.ProductID = u.ProductID
GROUP BY CASE WHEN c.ProductID IS NULL       THEN 'no cost history'
              WHEN u.StartDate < c.first_start THEN 'before first period'
              WHEN u.StartDate > c.last_end    THEN 'after last period'
              ELSE                                  'in a gap'
         END,
         p.FinishedGoodsFlag
ORDER BY work_orders DESC;
GO
-- Result (02 Nov 2026), work orders without a cost period:
--   no cost history, components:      23,050 orders, 27 products,
--                                      8,512 scrapped units, 18 products
--                                      with StandardCost = 0
--   before first period, finished:     7,307 orders, 24 products, 502 units
--   after last period, finished:       6,439 orders, 44 products, 440 units
--   no cost history, finished:           498 orders,  2 products,   3 units
-- Finished goods can all be costed (carry first period back, last period
-- forward, or use StandardCost). Components hold 80% of scrapped units
-- and have no cost history; 18 of 27 have StandardCost = 0.


-- =====================================================================
-- fact_work_order: can components be costed at all?
-- =====================================================================

-- For the 27 components: scrapped units split by whether a standard cost
-- exists, and whether the component is ever bought from a vendor
-- (a purchase price could serve as a cost proxy).
-- (First version put EXISTS inside SUM, which SQL Server does not allow:
-- Msg 130. Purchased products are now joined from a list instead.)
WITH comp AS (
    SELECT  w.ProductID,
            COUNT(*)           AS work_orders,
            SUM(w.ScrappedQty) AS scrapped_qty
    FROM Production.WorkOrder w
    JOIN Production.Product p ON p.ProductID = w.ProductID
    WHERE p.FinishedGoodsFlag = 0
    GROUP BY w.ProductID
),
purchased AS (
    SELECT DISTINCT ProductID FROM Purchasing.PurchaseOrderDetail
)
SELECT  CASE WHEN p.StandardCost > 0 THEN 'has standard cost' ELSE 'standard cost = 0' END AS cost_status,
        COUNT(*)                                                   AS products,
        SUM(c.work_orders)                                         AS work_orders,
        SUM(c.scrapped_qty)                                        AS scrapped_qty,
        SUM(CASE WHEN pu.ProductID IS NOT NULL THEN 1 ELSE 0 END)  AS products_also_purchased
FROM comp c
JOIN Production.Product p ON p.ProductID = c.ProductID
LEFT JOIN purchased pu    ON pu.ProductID = c.ProductID
GROUP BY CASE WHEN p.StandardCost > 0 THEN 'has standard cost' ELSE 'standard cost = 0' END;
GO
-- Result (02 Nov 2026): 9 components have a standard cost (143 scrapped
-- units); 18 have StandardCost = 0 (8,369 scrapped units). No component is
-- ever purchased, so there is no purchase-price proxy.
-- Scrap cost can be valued for 2,282 of 10,651 scrapped units (21.4%):
-- finished goods 2,139 + components with a standard cost 143.
-- Decisions:
--   - P6 headline KPI = scrap rate (scrapped / ordered units), by reason,
--     product and month. Works for every work order.
--   - unit_cost, scrap_cost and cost_source are stored (history, carried
--     back, carried forward, standard cost, unknown). Unknown = NULL,
--     never 0. Scrap cost stays hidden while coverage is low; a data
--     quality check reports coverage on every load.
--   - WorkOrder has no location column: dim_location is not linked to
--     fact_work_order (bus matrix corrected).