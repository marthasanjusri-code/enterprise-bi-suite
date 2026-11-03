/*
  fact_inventory_current_checks.sql
  Design checks for dw.fact_inventory_current (one row per product per
  location, current stock): grain, snapshot date, quantities, locations,
  stock limits and stock value coverage.

  Source: AdventureWorks2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- fact_inventory_current: one row per product per location (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. Grain: is product + location unique?
SELECT  COUNT(*)                                          AS inventory_rows,
        COUNT(DISTINCT CONCAT(ProductID, '|', LocationID)) AS distinct_product_locations,
        COUNT(DISTINCT ProductID)                         AS products,
        COUNT(DISTINCT LocationID)                        AS locations
FROM Production.ProductInventory;

-- 2. Snapshot date: one date for all rows, or many different dates?
SELECT  CAST(MIN(ModifiedDate) AS date)        AS first_modified,
        CAST(MAX(ModifiedDate) AS date)        AS last_modified,
        COUNT(DISTINCT CAST(ModifiedDate AS date)) AS distinct_dates
FROM Production.ProductInventory;

-- 3. Quantities: zero or negative stock?
SELECT  SUM(CASE WHEN Quantity = 0 THEN 1 ELSE 0 END) AS rows_with_zero,
        SUM(CASE WHEN Quantity < 0 THEN 1 ELSE 0 END) AS rows_negative,
        MIN(Quantity)                                 AS min_qty,
        MAX(Quantity)                                 AS max_qty,
        SUM(CAST(Quantity AS bigint))                 AS total_units
FROM Production.ProductInventory;

-- 4. Locations: what is stored where (finished goods vs components)?
SELECT  l.LocationID,
        l.Name                                            AS location,
        SUM(CASE WHEN p.FinishedGoodsFlag = 1 THEN 1 ELSE 0 END) AS finished_good_rows,
        SUM(CASE WHEN p.FinishedGoodsFlag = 0 THEN 1 ELSE 0 END) AS component_rows,
        SUM(CAST(i.Quantity AS bigint))                   AS units
FROM Production.ProductInventory i
JOIN Production.Location l ON l.LocationID = i.LocationID
JOIN Production.Product  p ON p.ProductID  = i.ProductID
GROUP BY l.LocationID, l.Name
ORDER BY l.LocationID;

-- 5. Stock limits (P4, P8): how many products are below their safety
--    stock or reorder point, counting stock across all locations?
WITH stock AS (
    SELECT ProductID, SUM(Quantity) AS qty
    FROM Production.ProductInventory
    GROUP BY ProductID
)
SELECT  p.FinishedGoodsFlag,
        COUNT(*)                                                        AS products_in_stock,
        SUM(CASE WHEN s.qty < p.SafetyStockLevel THEN 1 ELSE 0 END)     AS below_safety_stock,
        SUM(CASE WHEN s.qty < p.ReorderPoint     THEN 1 ELSE 0 END)     AS below_reorder_point,
        SUM(CASE WHEN p.ReorderPoint > p.SafetyStockLevel THEN 1 ELSE 0 END) AS reorder_above_safety
FROM stock s
JOIN Production.Product p ON p.ProductID = s.ProductID
GROUP BY p.FinishedGoodsFlag;

-- 6. Stock value: how many stocked units have a known cost?
--    (StandardCost = 0 means unknown, as found for components.)
SELECT  p.FinishedGoodsFlag,
        SUM(CAST(i.Quantity AS bigint))                                   AS units,
        SUM(CASE WHEN p.StandardCost > 0 THEN CAST(i.Quantity AS bigint) ELSE 0 END) AS units_with_cost,
        CAST(SUM(i.Quantity * p.StandardCost) AS decimal(18,2))           AS stock_value_known
FROM Production.ProductInventory i
JOIN Production.Product p ON p.ProductID = i.ProductID
GROUP BY p.FinishedGoodsFlag;
GO
-- Results (03 Nov 2026):
--   1. 1,069 rows = 1,069 product + location pairs; 432 products, 14 locations.
--   2. ModifiedDate runs 2019-03-31 to 2025-08-11 over 24 dates: it is the
--      last change of each row, not a snapshot date. Stock "as of" the
--      latest date (2025-08-11) is the current picture.
--   3. 4 rows with zero stock, none negative. Max 924, total 335,974 units.
--   4. Finished Goods Storage holds only finished goods (151 rows); finished
--      goods also sit in production locations (Subassembly 72 rows, Final
--      Assembly 113). Components sit in production and storage locations.
--   5. Components: 209 in stock, 55 below safety stock, 2 below reorder
--      point. Finished goods: 223, 14 below safety, 5 below reorder.
--      For NO product is ReorderPoint above SafetyStockLevel, the opposite
--      of the usual textbook rule (reorder point = safety stock + demand
--      during lead time).
--   6. Finished goods: 77,818 units, all with a cost, value 19.23 M.
--      Components: 258,156 units, only 7,348 (2.8%) with a cost.


-- =====================================================================
-- fact_inventory_current: what does the source itself mean by stock,
-- safety stock and reorder point?
-- =====================================================================

-- A. The source's own stock function: which locations does it count?
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.ufnGetStock')) AS ufnGetStock_definition;

-- B. Official descriptions of the stock-limit and inventory columns.
SELECT  OBJECT_SCHEMA_NAME(ep.major_id) + '.' + OBJECT_NAME(ep.major_id) AS table_name,
        c.name                                                        AS column_name,
        CAST(ep.value AS nvarchar(500))                               AS description
FROM sys.extended_properties ep
JOIN sys.columns c ON c.object_id = ep.major_id
                  AND c.column_id = ep.minor_id
WHERE ep.name = 'MS_Description'
  AND ep.class = 1
  AND (   (ep.major_id = OBJECT_ID('Production.Product')
           AND c.name IN ('SafetyStockLevel', 'ReorderPoint', 'StandardCost'))
       OR (ep.major_id = OBJECT_ID('Production.ProductInventory')
           AND c.name IN ('Quantity', 'LocationID', 'ModifiedDate')))
ORDER BY table_name, column_name;
GO
-- Results (03 Nov 2026):
--   A. ufnGetStock ("used internally only") sums stock in LocationID 6,
--      Miscellaneous Storage, only. It ignores Finished Goods Storage, so
--      it is a sample helper, not a business definition of available stock.
--   B. ReorderPoint = "Inventory level that triggers a purchase order or
--      work order." SafetyStockLevel = "Minimum inventory quantity."
--      So by the source's own words, the reorder point is the trigger and
--      safety stock is the minimum, even though the values are set
--      opposite to the textbook rule. Use each column for its stated role.

-- C. Can locations be classified from data? Work centers have a cost rate
--    and available hours; pure storage locations should have neither.
SELECT  l.LocationID,
        l.Name            AS location,
        l.CostRate,
        l.Availability,
        COUNT(i.ProductID)               AS inventory_rows,
        SUM(CAST(i.Quantity AS bigint))  AS units,
        (SELECT COUNT(*) FROM Production.WorkOrderRouting r
          WHERE r.LocationID = l.LocationID) AS routing_steps
FROM Production.Location l
LEFT JOIN Production.ProductInventory i ON i.LocationID = l.LocationID
GROUP BY l.LocationID, l.Name, l.CostRate, l.Availability
ORDER BY l.LocationID;
GO
-- Result (03 Nov 2026): a clean split on three separate signals.
--   Locations 1-7 (Tool Crib, Sheet Metal Racks, Paint Shop, Paint Storage,
--   Metal Storage, Miscellaneous Storage, Finished Goods Storage): cost rate
--   0, availability 0, no routing steps -> STORAGE (199,531 units).
--   Locations 10-60 (Frame Forming, Frame Welding, Debur and Polish, Paint,
--   Specialized Paint, Subassembly, Final Assembly): cost rate and hours
--   above 0, all routing steps -> WORK CENTRE (136,443 units).
-- Decision: dim_location.location_type = 'Work centre' when CostRate > 0
-- or Availability > 0, else 'Storage'. Available stock = storage
-- locations; work in progress = work centres; on hand = both.


-- =====================================================================
-- fact_inventory_current: stock status on available vs on-hand stock,
-- and products with no inventory row at all
-- =====================================================================

-- D. How many products land in each status if we use available
--    (storage) stock, compared with on-hand stock? Products still on sale
--    with no inventory row count as zero stock, so they are included too.
WITH loc AS (
    SELECT LocationID,
           CASE WHEN CostRate > 0 OR Availability > 0 THEN 'Work centre' ELSE 'Storage' END AS location_type
    FROM Production.Location
),
stock AS (
    SELECT  i.ProductID,
            SUM(CASE WHEN l.location_type = 'Storage' THEN i.Quantity ELSE 0 END) AS available_qty,
            SUM(i.Quantity)                                                    AS on_hand_qty
    FROM Production.ProductInventory i
    JOIN loc l ON l.LocationID = i.LocationID
    GROUP BY i.ProductID
),
products AS (
    SELECT  p.ProductID, p.FinishedGoodsFlag, p.SafetyStockLevel, p.ReorderPoint,
            ISNULL(s.available_qty, 0) AS available_qty,
            ISNULL(s.on_hand_qty, 0)   AS on_hand_qty,
            CASE WHEN s.ProductID IS NULL THEN 1 ELSE 0 END AS no_inventory_row
    FROM Production.Product p
    LEFT JOIN stock s ON s.ProductID = p.ProductID
    WHERE p.SellEndDate IS NULL
)
SELECT  FinishedGoodsFlag,
        COUNT(*)                                                          AS active_products,
        SUM(no_inventory_row)                                             AS no_inventory_row,
        SUM(CASE WHEN available_qty < ReorderPoint THEN 1 ELSE 0 END)     AS reorder_now_available,
        SUM(CASE WHEN available_qty >= ReorderPoint
                  AND available_qty < SafetyStockLevel THEN 1 ELSE 0 END) AS below_minimum_available,
        SUM(CASE WHEN on_hand_qty < ReorderPoint THEN 1 ELSE 0 END)       AS reorder_now_on_hand,
        SUM(CASE WHEN on_hand_qty >= ReorderPoint
                  AND on_hand_qty < SafetyStockLevel THEN 1 ELSE 0 END)   AS below_minimum_on_hand
FROM products
GROUP BY FinishedGoodsFlag;
GO
-- Result (03 Nov 2026), products still on sale:
--   Components: 209, all with inventory rows. Available stock: 98 reorder
--   now, 24 below minimum. On-hand stock: 2 reorder now, 53 below minimum.
--   Finished goods: 197, of which 54 have NO inventory row (zero stock).
--   Available stock: 118 reorder now, 27 below minimum. On-hand stock:
--   58 reorder now (54 of them the zero-stock products), 9 below minimum.
-- Decisions:
--   - Stock status (Reorder now / Below minimum / OK) compares the reorder
--     point and safety stock with the INVENTORY POSITION: on-hand stock
--     (storage + work in progress) + open purchase quantity. This is the
--     standard trigger quantity; open purchase quantity is about 0 today
--     but is included for future loads.
--   - Available (storage) stock is shown separately as "ready to ship".
--   - Active products with no inventory row get one zero-quantity row
--     (location = "No stock location"), so they cannot disappear from the
--     reorder list.


-- =====================================================================
-- fact_inventory_current: can purchased internal parts be valued at
-- their last purchase price?
-- =====================================================================

-- E. dim_product checks showed 182 internal parts are bought from vendors
--    but have StandardCost = 0. Their last purchase price could value the
--    stock ("last purchase price" costing). How much stock would that add?
WITH last_price AS (
    SELECT  d.ProductID,
            d.UnitPrice,
            ROW_NUMBER() OVER (PARTITION BY d.ProductID
                               ORDER BY h.OrderDate DESC, d.PurchaseOrderDetailID DESC) AS rn
    FROM Purchasing.PurchaseOrderDetail d
    JOIN Purchasing.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
),
stock AS (
    SELECT  p.FinishedGoodsFlag,
            i.Quantity,
            CASE WHEN p.StandardCost > 0           THEN 'standard cost'
                 WHEN lp.UnitPrice IS NOT NULL      THEN 'last purchase price'
                 ELSE                                    'no cost' END AS cost_source,
            CASE WHEN p.StandardCost > 0 THEN p.StandardCost ELSE lp.UnitPrice END AS unit_cost
    FROM Production.ProductInventory i
    JOIN Production.Product p ON p.ProductID = i.ProductID
    LEFT JOIN last_price lp   ON lp.ProductID = i.ProductID AND lp.rn = 1
)
SELECT  FinishedGoodsFlag,
        cost_source,
        SUM(CAST(Quantity AS bigint))                     AS units,
        CAST(SUM(Quantity * unit_cost) AS decimal(18,2))  AS stock_value
FROM stock
GROUP BY FinishedGoodsFlag, cost_source
ORDER BY FinishedGoodsFlag, cost_source;
GO
-- Result (03 Nov 2026):
--   Internal parts: last purchase price 228,992 units (8.43 M), standard
--   cost 7,348 units (0.87 M), no cost 21,816 units.
--   Finished goods: standard cost 77,818 units (19.23 M).
--   Internal-part units with a cost rise from 2.8% to 91.5%; all stock
--   from 2.8% / 100% to 93.5% of units overall (314,158 of 335,974).
-- Decision (updates the earlier cost rule): unit_cost = standard cost when
-- above 0, else last purchase price, else NULL. cost_source records which
-- one was used. Weighted average cost would be closer to accounting
-- practice; last purchase price is the documented, simpler choice.