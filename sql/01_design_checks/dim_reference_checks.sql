/*
  dim_reference_checks.sql
  Design checks for the small reference dimensions: dw.dim_promotion,
  dw.dim_ship_method, dw.dim_vendor and dw.dim_shift.

  Source: AdventureWorks2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

USE AdventureWorks2025;
GO

-- =====================================================================
-- dim_promotion
-- =====================================================================

-- 1. Every offer, and how many sales lines use it. Is there a "no
--    discount" offer, so lines without a promotion need no special row?
SELECT  o.SpecialOfferID,
        o.Description,
        o.Type,
        o.Category,
        o.DiscountPct,
        CAST(o.StartDate AS date)        AS start_date,
        CAST(o.EndDate   AS date)        AS end_date,
        COUNT(d.SalesOrderDetailID)      AS sales_lines
FROM Sales.SpecialOffer o
LEFT JOIN Sales.SalesOrderDetail d ON d.SpecialOfferID = o.SpecialOfferID
GROUP BY o.SpecialOfferID, o.Description, o.Type, o.Category, o.DiscountPct,
         o.StartDate, o.EndDate
ORDER BY o.SpecialOfferID;

-- 2. Does each line's discount equal its offer's discount?
SELECT  COUNT(*)                                                         AS sales_lines,
        SUM(CASE WHEN d.UnitPriceDiscount <> o.DiscountPct THEN 1 ELSE 0 END) AS discount_differs
FROM Sales.SalesOrderDetail d
JOIN Sales.SpecialOffer o ON o.SpecialOfferID = d.SpecialOfferID;

-- =====================================================================
-- dim_ship_method
-- =====================================================================

-- 3. Ship methods and how often sales and purchases use them.
SELECT  s.ShipMethodID,
        s.Name,
        s.ShipBase,
        s.ShipRate,
        (SELECT COUNT(*) FROM Sales.SalesOrderHeader h
          WHERE h.ShipMethodID = s.ShipMethodID)        AS sales_orders,
        (SELECT COUNT(*) FROM Purchasing.PurchaseOrderHeader h
          WHERE h.ShipMethodID = s.ShipMethodID)        AS purchase_orders
FROM Purchasing.ShipMethod s
ORDER BY s.ShipMethodID;

-- =====================================================================
-- dim_vendor
-- =====================================================================

-- 4. Vendor names unique? Do vendors have an address (country), which
--    would allow "spend by vendor country"?
WITH vendor_country AS (
    SELECT  bea.BusinessEntityID,
            MIN(cr.Name) AS country,
            COUNT(DISTINCT cr.Name) AS countries
    FROM Person.BusinessEntityAddress bea
    JOIN Person.Address a          ON a.AddressID = bea.AddressID
    JOIN Person.StateProvince sp   ON sp.StateProvinceID = a.StateProvinceID
    JOIN Person.CountryRegion cr   ON cr.CountryRegionCode = sp.CountryRegionCode
    GROUP BY bea.BusinessEntityID
)
SELECT  COUNT(*)                                              AS vendors,
        COUNT(DISTINCT v.Name)                                AS distinct_names,
        SUM(CASE WHEN vc.BusinessEntityID IS NULL THEN 1 ELSE 0 END) AS without_address,
        SUM(CASE WHEN vc.countries > 1 THEN 1 ELSE 0 END)     AS in_several_countries
FROM Purchasing.Vendor v
LEFT JOIN vendor_country vc ON vc.BusinessEntityID = v.BusinessEntityID;

-- 5. Vendors by country (only meaningful if check 4 shows addresses).
SELECT  cr.Name   AS country,
        COUNT(DISTINCT v.BusinessEntityID) AS vendors
FROM Purchasing.Vendor v
JOIN Person.BusinessEntityAddress bea ON bea.BusinessEntityID = v.BusinessEntityID
JOIN Person.Address a                 ON a.AddressID = bea.AddressID
JOIN Person.StateProvince sp          ON sp.StateProvinceID = a.StateProvinceID
JOIN Person.CountryRegion cr          ON cr.CountryRegionCode = sp.CountryRegionCode
GROUP BY cr.Name
ORDER BY vendors DESC;

-- =====================================================================
-- dim_shift
-- =====================================================================

-- 6. Shifts, their times, and current employees per shift.
SELECT  s.ShiftID,
        s.Name,
        CAST(s.StartTime AS varchar(8)) AS start_time,
        CAST(s.EndTime   AS varchar(8)) AS end_time,
        COUNT(h.BusinessEntityID)       AS current_employees
FROM HumanResources.Shift s
LEFT JOIN HumanResources.EmployeeDepartmentHistory h
       ON h.ShiftID = s.ShiftID AND h.EndDate IS NULL
GROUP BY s.ShiftID, s.Name, s.StartTime, s.EndTime
ORDER BY s.ShiftID;
GO