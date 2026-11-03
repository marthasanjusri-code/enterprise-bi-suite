/*
  dim_customer_checks.sql
  Design checks for dw.dim_customer: customer types (individual or store),
  customers with and without orders, stores and their salespeople, and the
  home territory of customers.

  Source: AdventureWorks2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- dim_customer: one row per customer (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. Customer types: person only, store only, or both (store contact)?
SELECT  CASE WHEN PersonID IS NOT NULL AND StoreID IS NULL     THEN 'individual'
             WHEN PersonID IS NULL     AND StoreID IS NOT NULL THEN 'store'
             WHEN PersonID IS NOT NULL AND StoreID IS NOT NULL THEN 'store with contact person'
             ELSE 'neither' END AS customer_type,
        COUNT(*) AS customers
FROM Sales.Customer
GROUP BY CASE WHEN PersonID IS NOT NULL AND StoreID IS NULL     THEN 'individual'
              WHEN PersonID IS NULL     AND StoreID IS NOT NULL THEN 'store'
              WHEN PersonID IS NOT NULL AND StoreID IS NOT NULL THEN 'store with contact person'
              ELSE 'neither' END;

-- 2. Which customer types actually place orders, and through which channel?
SELECT  CASE WHEN c.StoreID IS NULL THEN 'individual' ELSE 'store' END AS customer_type,
        CASE WHEN h.OnlineOrderFlag = 1 THEN 'Online' ELSE 'Reseller' END AS channel,
        COUNT(DISTINCT c.CustomerID) AS customers,
        COUNT(*)                     AS orders
FROM Sales.SalesOrderHeader h
JOIN Sales.Customer c ON c.CustomerID = h.CustomerID
GROUP BY CASE WHEN c.StoreID IS NULL THEN 'individual' ELSE 'store' END,
         CASE WHEN h.OnlineOrderFlag = 1 THEN 'Online' ELSE 'Reseller' END;

-- 3. Customers without any order.
WITH ordered AS (
    SELECT DISTINCT CustomerID FROM Sales.SalesOrderHeader
)
SELECT  CASE WHEN c.StoreID IS NULL THEN 'individual' ELSE 'store' END AS customer_type,
        COUNT(*)                                                      AS customers,
        SUM(CASE WHEN o.CustomerID IS NULL THEN 1 ELSE 0 END)          AS without_orders
FROM Sales.Customer c
LEFT JOIN ordered o ON o.CustomerID = c.CustomerID
GROUP BY CASE WHEN c.StoreID IS NULL THEN 'individual' ELSE 'store' END;

-- 4. Stores: does every store have a salesperson, and is store name unique?
SELECT  COUNT(*)                                             AS stores,
        COUNT(DISTINCT Name)                                 AS distinct_store_names,
        SUM(CASE WHEN SalesPersonID IS NULL THEN 1 ELSE 0 END) AS without_salesperson
FROM Sales.Store;

-- 5. Customers by home region group.
SELECT  t.[Group]  AS region_group,
        COUNT(*)   AS customers
FROM Sales.Customer c
JOIN Sales.SalesTerritory t ON t.TerritoryID = c.TerritoryID
GROUP BY t.[Group]
ORDER BY customers DESC;
GO
-- Results (03 Nov 2026):
--   1. 18,484 individuals, 701 store-only rows, 635 store rows with a
--      contact person (19,820 customers).
--   2. Individuals: 18,484 customers, 27,659 orders, all Online.
--      Stores: 635 customers (all "store with contact person"), 3,806
--      orders, all Reseller.
--   3. Every individual has ordered. Of 1,336 store customers, 701 have no
--      orders: the 701 store-only rows. Store orders are placed through the
--      store + contact person customer rows.
--   4. 701 stores, 699 distinct names (2 names shared), all with a
--      salesperson.
--   5. Home region: North America 10,428, Europe 5,727, Pacific 3,665.
-- Decisions:
--   - customer_type = Individual / Store; has_orders flag (store-only rows
--     kept but hidden from slicers).
--   - "Number of customers" counts customers WITH orders in the period,
--     never dimension rows.
--   - Individuals: no personal names; label = "Individual " + account number.
--   - Stores: label = store name, plus the account number when the name is
--     shared by more than one store.
--   - Home territory kept as text columns (home_territory, home_region_group);
--     region security uses the order's territory in the fact.