/*
  dim_product_checks.sql
  Design checks for dw.dim_product: keys, category structure, missing
  attributes, costs and prices, which facts use each product, and sales
  outside the selling period.

  Source: AdventureWorks2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- dim_product: one row per product (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. Keys and basic gaps: are ProductNumber and Name unique? How many
--    products have no subcategory, zero cost, zero price, or a sell end?
SELECT  COUNT(*)                                                     AS products,
        COUNT(DISTINCT ProductNumber)                                AS distinct_numbers,
        COUNT(DISTINCT Name)                                         AS distinct_names,
        SUM(CASE WHEN ProductSubcategoryID IS NULL THEN 1 ELSE 0 END) AS no_subcategory,
        SUM(CASE WHEN ProductSubcategoryID IS NULL
                  AND FinishedGoodsFlag = 1 THEN 1 ELSE 0 END)       AS finished_without_subcategory,
        SUM(CASE WHEN StandardCost = 0 THEN 1 ELSE 0 END)            AS zero_cost,
        SUM(CASE WHEN ListPrice    = 0 THEN 1 ELSE 0 END)            AS zero_price,
        SUM(CASE WHEN SellEndDate IS NOT NULL THEN 1 ELSE 0 END)     AS sell_ended
FROM Production.Product;

-- 2. Category structure: categories, subcategories and products.
SELECT  c.Name                                  AS category,
        COUNT(DISTINCT s.ProductSubcategoryID)  AS subcategories,
        COUNT(p.ProductID)                      AS products
FROM Production.ProductCategory c
JOIN Production.ProductSubcategory s ON s.ProductCategoryID = c.ProductCategoryID
LEFT JOIN Production.Product p       ON p.ProductSubcategoryID = s.ProductSubcategoryID
GROUP BY c.Name
ORDER BY c.Name;

-- 3. Missing descriptive attributes (shown as "N/A" if kept).
SELECT  SUM(CASE WHEN Color       IS NULL THEN 1 ELSE 0 END) AS no_color,
        SUM(CASE WHEN Size        IS NULL THEN 1 ELSE 0 END) AS no_size,
        SUM(CASE WHEN ProductLine IS NULL THEN 1 ELSE 0 END) AS no_product_line,
        SUM(CASE WHEN Class       IS NULL THEN 1 ELSE 0 END) AS no_class,
        SUM(CASE WHEN Style       IS NULL THEN 1 ELSE 0 END) AS no_style
FROM Production.Product;

-- 4. Which facts use each product? Products used nowhere could be
--    hidden from slicers.
WITH usage AS (
    SELECT  p.ProductID,
            p.FinishedGoodsFlag,
            CASE WHEN EXISTS (SELECT 1 FROM Sales.SalesOrderDetail d
                              WHERE d.ProductID = p.ProductID) THEN 1 ELSE 0 END AS sold,
            CASE WHEN EXISTS (SELECT 1 FROM Purchasing.PurchaseOrderDetail d
                              WHERE d.ProductID = p.ProductID) THEN 1 ELSE 0 END AS purchased,
            CASE WHEN EXISTS (SELECT 1 FROM Production.WorkOrder w
                              WHERE w.ProductID = p.ProductID) THEN 1 ELSE 0 END AS made,
            CASE WHEN EXISTS (SELECT 1 FROM Production.ProductInventory i
                              WHERE i.ProductID = p.ProductID) THEN 1 ELSE 0 END AS stocked
    FROM Production.Product p
)
SELECT  FinishedGoodsFlag,
        COUNT(*)        AS products,
        SUM(sold)       AS sold,
        SUM(purchased)  AS purchased,
        SUM(made)       AS made,
        SUM(stocked)    AS stocked,
        SUM(CASE WHEN sold + purchased + made + stocked = 0 THEN 1 ELSE 0 END) AS used_nowhere
FROM usage
GROUP BY FinishedGoodsFlag;

-- 5. Sales outside the selling period (before SellStartDate or after
--    SellEndDate)?
SELECT  SUM(CASE WHEN h.OrderDate < p.SellStartDate THEN 1 ELSE 0 END)  AS lines_before_sell_start,
        SUM(CASE WHEN p.SellEndDate IS NOT NULL
                  AND h.OrderDate > p.SellEndDate THEN 1 ELSE 0 END)    AS lines_after_sell_end,
        COUNT(DISTINCT CASE WHEN p.SellEndDate IS NOT NULL
                             AND h.OrderDate > p.SellEndDate
                            THEN p.ProductID END)                       AS products_sold_after_end
FROM Sales.SalesOrderDetail d
JOIN Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID
JOIN Production.Product p     ON p.ProductID    = d.ProductID;
GO
-- Results (03 Nov 2026):
--   1. 504 products, numbers and names unique. 209 without subcategory, and
--      0 of them are finished goods: they are exactly the 209 internal
--      parts. 200 with zero cost and 200 with zero price. 98 sell-ended.
--   2. Accessories 12 subcategories / 29 products, Bikes 3 / 97,
--      Clothing 8 / 35, Components 14 / 134 (= 295 finished goods).
--      Note: the category "Components" holds SELLABLE parts; the 209
--      internal parts (FinishedGoodsFlag = 0) are a different group.
--   3. No color 248, size 293, product line 226, class 257, style 293.
--   4. Internal parts: 0 sold, 182 purchased, 27 made, 209 stocked.
--      Finished goods: 266 sold, 83 purchased, 211 made, 223 stocked,
--      1 used nowhere.
--   5. 0 lines before sell start; 64 lines on 25 products after sell end:
--      the same count as the 64 lines with no cost period (cost history
--      ended when the products were discontinued). Build test to confirm.
-- Decisions:
--   - Internal parts get category and subcategory "Internal parts", so they
--     are not confused with the sellable "Components" category.
--   - Missing attributes shown as "N/A"; codes shown as words (R = Road).
--   - standard_cost and list_price: 0 is stored as NULL (unknown).
--   - Type 1 (current values only); cost history lives in the facts.
--   - The unused product is kept (harmless, keeps the list complete).