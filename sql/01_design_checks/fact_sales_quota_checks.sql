/*
  fact_sales_quota_checks.sql
  Design checks for dw.fact_sales_quota (one row per salesperson per
  quota period): quota calendar, the period a quota covers, and how each
  quota row gets a territory.

  Source: AdventureWorks2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

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

-- Result (01 Nov 2026): 280 sold in Northwest 2022-05-30 to 2025-04-30
-- (95 orders) despite territory history ending 2023-09-29. 284 sold in
-- Northwest from 2023-09-30 (140 orders). Both quotas belong to Northwest.
-- Territory rule: covering period > nearest period > region from orders.