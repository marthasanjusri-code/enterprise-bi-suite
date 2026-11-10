/*
  fact_purchase_checks.sql
  Design checks for dw.fact_purchase (one row per purchase order line):
  money and quantity consistency, status, dates, lead time, value
  measures and freight allocation.

  Source: AdventureWorks2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- fact_purchase: one row per purchase order line (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. Grain: PurchaseOrderDetailID unique?
SELECT  COUNT(*)                              AS po_lines,
        COUNT(DISTINCT PurchaseOrderDetailID) AS distinct_line_ids,
        COUNT(DISTINCT PurchaseOrderID)       AS purchase_orders
FROM Purchasing.PurchaseOrderDetail;

-- 2. Money: line total = qty x price, lines add up to SubTotal,
--    and TotalDue = SubTotal + TaxAmt + Freight?
SELECT  (SELECT COUNT(*) FROM Purchasing.PurchaseOrderDetail
          WHERE ABS(LineTotal - OrderQty * UnitPrice) > 0.01)             AS lines_where_line_total_differs,
        (SELECT COUNT(*) FROM Purchasing.PurchaseOrderHeader h
           JOIN (SELECT PurchaseOrderID, SUM(LineTotal) AS s
                 FROM Purchasing.PurchaseOrderDetail GROUP BY PurchaseOrderID) d
             ON d.PurchaseOrderID = h.PurchaseOrderID
          WHERE ABS(h.SubTotal - d.s) > 0.01)                               AS orders_where_subtotal_differs,
        (SELECT COUNT(*) FROM Purchasing.PurchaseOrderHeader
          WHERE ABS(TotalDue - (SubTotal + TaxAmt + Freight)) > 0.01)       AS orders_where_total_due_differs,
        (SELECT COUNT(*) FROM Purchasing.PurchaseOrderHeader h
          WHERE NOT EXISTS (SELECT 1 FROM Purchasing.PurchaseOrderDetail d
                            WHERE d.PurchaseOrderID = h.PurchaseOrderID))   AS orders_without_lines;

-- 3. Quantities: received <= ordered, stocked = received - rejected?
SELECT  SUM(CASE WHEN ReceivedQty > OrderQty                    THEN 1 ELSE 0 END) AS received_more_than_ordered,
        SUM(CASE WHEN ReceivedQty < OrderQty                    THEN 1 ELSE 0 END) AS received_less_than_ordered,
        SUM(CASE WHEN StockedQty <> ReceivedQty - RejectedQty   THEN 1 ELSE 0 END) AS stocked_not_received_minus_rejected,
        SUM(CASE WHEN RejectedQty > 0                           THEN 1 ELSE 0 END) AS lines_with_rejects
FROM Purchasing.PurchaseOrderDetail;

-- 4. Status vs quantities and money: does a Rejected or Pending order
--    still show received goods?
SELECT  h.Status,
        dbo.ufnGetPurchaseOrderStatusText(h.Status) AS status_text,
        COUNT(*)                                    AS po_lines,
        SUM(d.OrderQty)                             AS ordered_qty,
        SUM(d.ReceivedQty)                          AS received_qty,
        SUM(d.RejectedQty)                          AS rejected_qty,
        CAST(SUM(d.LineTotal) AS decimal(18,2))     AS line_total
FROM Purchasing.PurchaseOrderDetail d
JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
GROUP BY h.Status
ORDER BY h.Status;

-- 5. Dates: ship date (header) vs order date and line due date.
SELECT  SUM(CASE WHEN h.ShipDate IS NULL         THEN 1 ELSE 0 END) AS lines_missing_ship_date,
        SUM(CASE WHEN h.ShipDate < h.OrderDate   THEN 1 ELSE 0 END) AS shipped_before_order,
        SUM(CASE WHEN d.DueDate  < h.OrderDate   THEN 1 ELSE 0 END) AS due_before_order,
        SUM(CASE WHEN h.ShipDate > d.DueDate     THEN 1 ELSE 0 END) AS shipped_after_due,
        MIN(DATEDIFF(day, h.OrderDate, h.ShipDate)) AS min_days_to_ship,
        MAX(DATEDIFF(day, h.OrderDate, h.ShipDate)) AS max_days_to_ship,
        MIN(DATEDIFF(day, h.OrderDate, d.DueDate))  AS min_days_to_due,
        MAX(DATEDIFF(day, h.OrderDate, d.DueDate))  AS max_days_to_due
FROM Purchasing.PurchaseOrderDetail d
JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID;

-- 6. Vendor lead time: does every PO line's product + vendor pair exist
--    in ProductVendor? And what lead times are there?
SELECT  SUM(CASE WHEN pv.ProductID IS NULL THEN 1 ELSE 0 END) AS lines_without_product_vendor,
        COUNT(*)                                             AS po_lines,
        MIN(pv.AverageLeadTime)                              AS min_lead_days,
        MAX(pv.AverageLeadTime)                              AS max_lead_days
FROM Purchasing.PurchaseOrderDetail d
JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
LEFT JOIN Purchasing.ProductVendor pv
       ON pv.ProductID = d.ProductID
      AND pv.BusinessEntityID = h.VendorID;

-- 7. Buyers: who places purchase orders?
SELECT  e.JobTitle,
        COUNT(DISTINCT h.EmployeeID) AS employees,
        COUNT(*)                     AS purchase_orders
FROM Purchasing.PurchaseOrderHeader h
JOIN HumanResources.Employee e ON e.BusinessEntityID = h.EmployeeID
GROUP BY e.JobTitle
ORDER BY purchase_orders DESC;

-- 8. Vendors: how many have orders, and are any inactive or not preferred?
SELECT  v.ActiveFlag,
        v.PreferredVendorStatus,
        COUNT(DISTINCT v.BusinessEntityID)  AS vendors,
        COUNT(DISTINCT h.PurchaseOrderID)   AS purchase_orders
FROM Purchasing.Vendor v
LEFT JOIN Purchasing.PurchaseOrderHeader h ON h.VendorID = v.BusinessEntityID
GROUP BY v.ActiveFlag, v.PreferredVendorStatus
ORDER BY v.ActiveFlag DESC, v.PreferredVendorStatus DESC;
GO
-- Results 1-4 (02 Nov 2026):
--   1. 8,845 lines = 8,845 distinct IDs, 4,012 orders. Grain confirmed.
--   2. 0 / 0 / 0 / 0. LineTotal = qty x price; lines add up to SubTotal;
--      TotalDue = SubTotal + TaxAmt + Freight; every order has lines.
--   3. 0 received more than ordered; 380 lines received less (partial
--      deliveries); StockedQty = ReceivedQty - RejectedQty always;
--      563 lines have rejects.
--   4. By status (lines / ordered / received / rejected / line total):
--      Pending  477 / 125,801 / 124,537 /  1,510 /  3,505,773
--      Approved  57 /  96,255 /  95,965 /      0 /  2,164,339
--      Rejected 142 /  46,747 /  46,746 / 46,745 /  1,301,826
--      Complete 8,169 / 2,079,834 / 2,060,051 / 24,445 / 56,820,057
--   Reading: status does not track delivery. Pending and Approved orders
--   already received about 99% of goods. "Rejected" orders were received
--   and then almost fully rejected (quality), not cancelled.
--   Proposal: value KPIs from quantities, not from status:
--     ordered value  = line_total
--     received value = received_qty x unit_price
--     accepted value = stocked_qty  x unit_price  (= purchase spend)
--     rejected value = rejected_qty x unit_price
--   Status stays for order counts by stage (P2).
-- Results (02 Nov 2026):
--   1. 8,845 lines = 8,845 distinct IDs, 4,012 orders. Grain confirmed.
--   2. 0 / 0 / 0 / 0. Line totals, SubTotal, TotalDue all consistent.
--   3. 0 received more than ordered; 380 lines short-delivered;
--      stocked = received - rejected on every line; 563 lines with rejects.
--   4. Pending: 477 lines, 124,537 of 125,801 received. Approved: 57 lines,
--      95,965 of 96,255 received. Rejected: 142 lines, 46,746 received and
--      46,745 rejected. Complete: 8,169 lines.
--      Status does not mean "not delivered": Pending and Approved orders
--      already hold received goods; "Rejected" = goods rejected on receipt.
--   5. No missing ship date, none shipped before order. 7 lines due before
--      the order date, 7 shipped after due. Days to ship 9-25.
--   6. Every line has a product + vendor lead time (10-120 days).
--   7. Buyers 9 (3,089 POs), Purchasing Assistants 2 (763), Purchasing
--      Manager 1 (160).
--   8. 93 active preferred vendors (3,456 POs), 7 active not preferred
--      (353), 4 inactive (203). Inactive vendors have history: keep them.


-- =====================================================================
-- fact_purchase: anomaly lines and value measures
-- =====================================================================

-- A. Are the 7 "due before order" lines the same as the 7 "shipped after
--    due" lines? Show them.
SELECT  h.PurchaseOrderID,
        d.PurchaseOrderDetailID,
        CAST(h.OrderDate AS date) AS order_date,
        CAST(d.DueDate   AS date) AS due_date,
        CAST(h.ShipDate  AS date) AS ship_date,
        h.Status,
        d.OrderQty, d.ReceivedQty, d.RejectedQty
FROM Purchasing.PurchaseOrderDetail d
JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
WHERE d.DueDate < h.OrderDate
   OR h.ShipDate > d.DueDate
ORDER BY h.PurchaseOrderID, d.PurchaseOrderDetailID;

-- B. Value measures by status: ordered value (line total), accepted value
--    (stocked qty x price), rejected value (rejected qty x price), and
--    short-delivered value ((ordered - received) x price).
SELECT  h.Status,
        dbo.ufnGetPurchaseOrderStatusText(h.Status)                         AS status_text,
        CAST(SUM(d.LineTotal)                                AS decimal(18,2)) AS ordered_value,
        CAST(SUM(d.StockedQty  * d.UnitPrice)                AS decimal(18,2)) AS accepted_value,
        CAST(SUM(d.RejectedQty * d.UnitPrice)                AS decimal(18,2)) AS rejected_value,
        CAST(SUM((d.OrderQty - d.ReceivedQty) * d.UnitPrice) AS decimal(18,2)) AS short_delivered_value
FROM Purchasing.PurchaseOrderDetail d
JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
GROUP BY h.Status
ORDER BY h.Status;

-- C. Freight per order: if allocated to lines by line total share, does it
--    add back to the header freight exactly?
WITH alloc AS (
    SELECT  d.PurchaseOrderID,
            d.LineTotal / NULLIF(SUM(d.LineTotal) OVER (PARTITION BY d.PurchaseOrderID), 0)
              * h.Freight AS freight_allocated
    FROM Purchasing.PurchaseOrderDetail d
    JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
)
SELECT  CAST(SUM(a.freight_allocated) AS decimal(18,2))                      AS allocated_freight,
        CAST((SELECT SUM(Freight) FROM Purchasing.PurchaseOrderHeader) AS decimal(18,2)) AS header_freight
FROM alloc a;
GO
-- Results (02 Nov 2026):
--   A. The same 7 lines fail both date checks: PO 4003 (1 line, due
--      162 days before the order) and PO 4006 (6 lines, due 7 days before
--      the order). Both Approved. Every other line shipped by its due date,
--      so vendor on-time % is constant (hidden, like sales shipping).
--   B. For every status: ordered value = accepted + rejected +
--      short-delivered value, exactly. Accepted value (spend) = 61.21 M
--      across all statuses; Complete-only line total would be 56.82 M.
--   C. Allocated freight 1,583,807.70 vs header freight 1,583,978.23:
--      170.53 lost in the allocation.

-- D. Why was freight lost? Either money division rounding (money / money
--    keeps only 4 decimals) or orders with freight but zero line total.
WITH alloc AS (
    SELECT  d.PurchaseOrderID,
            CAST(d.LineTotal AS decimal(38,10))
              / NULLIF(SUM(CAST(d.LineTotal AS decimal(38,10)))
                       OVER (PARTITION BY d.PurchaseOrderID), 0)
              * CAST(h.Freight AS decimal(38,10)) AS freight_allocated
    FROM Purchasing.PurchaseOrderDetail d
    JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
)
SELECT  CAST(SUM(a.freight_allocated) AS decimal(18,2))                                  AS allocated_freight_decimal,
        CAST((SELECT SUM(Freight) FROM Purchasing.PurchaseOrderHeader) AS decimal(18,2)) AS header_freight,
        (SELECT COUNT(*) FROM Purchasing.PurchaseOrderHeader
          WHERE SubTotal = 0 AND Freight > 0)                                            AS zero_value_orders_with_freight
FROM alloc a;
GO
-- Result (02 Nov 2026): with decimals, allocated freight 1,583,976.71 vs
-- header 1,583,978.23 (gap 1.52, down from 170.53). 0 zero-value orders
-- with freight. Cause = rounding in the division, not missing orders.
-- Decision: allocate by line-total share rounded to cents, and give each
-- order's rounding remainder to its largest line, so the allocation adds
-- back exactly by construction. Test after build: 0 orders where the sum
-- of allocated freight differs from header freight.


-- =====================================================================
-- fact_purchase: checks behind the KPI definitions
-- =====================================================================

-- E. Freight is usually driven by weight. Could we allocate by weight
--    instead of value? Only if purchased products have a weight.
SELECT  COUNT(*)                                             AS po_lines,
        SUM(CASE WHEN p.Weight IS NULL THEN 1 ELSE 0 END)    AS lines_without_weight,
        COUNT(DISTINCT d.ProductID)                          AS products_bought,
        COUNT(DISTINCT CASE WHEN p.Weight IS NULL THEN d.ProductID END) AS products_without_weight
FROM Purchasing.PurchaseOrderDetail d
JOIN Production.Product p ON p.ProductID = d.ProductID;

-- F. Fill rate should only judge lines whose due date has passed.
--    How many lines are still "open" at the end of the purchase data,
--    and are the short deliveries among them?
-- (First version used a subquery inside SUM, which SQL Server does not
-- allow: Msg 130. The data end date is now joined once instead.)
WITH data_end AS (
    SELECT MAX(ShipDate) AS last_date FROM Purchasing.PurchaseOrderHeader
)
SELECT  CAST(e.last_date AS date)                                       AS data_end,
        SUM(CASE WHEN d.DueDate > e.last_date THEN 1 ELSE 0 END)        AS lines_not_yet_due,
        SUM(CASE WHEN d.ReceivedQty < d.OrderQty
                  AND d.DueDate > e.last_date THEN 1 ELSE 0 END)        AS short_lines_not_yet_due,
        SUM(CASE WHEN d.ReceivedQty < d.OrderQty THEN 1 ELSE 0 END)     AS short_lines_total
FROM Purchasing.PurchaseOrderDetail d
CROSS JOIN data_end e
GROUP BY e.last_date;

-- G. Line-level OTIF (on time, in full, no rejects): does it vary?
SELECT  COUNT(*) AS po_lines,
        SUM(CASE WHEN h.ShipDate <= d.DueDate                     THEN 1 ELSE 0 END) AS on_time_lines,
        SUM(CASE WHEN d.ReceivedQty = d.OrderQty                  THEN 1 ELSE 0 END) AS in_full_lines,
        SUM(CASE WHEN d.RejectedQty = 0                           THEN 1 ELSE 0 END) AS no_reject_lines,
        SUM(CASE WHEN h.ShipDate <= d.DueDate
                  AND d.ReceivedQty = d.OrderQty
                  AND d.RejectedQty = 0                           THEN 1 ELSE 0 END) AS otif_lines
FROM Purchasing.PurchaseOrderDetail d
JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
WHERE d.DueDate >= h.OrderDate;
GO