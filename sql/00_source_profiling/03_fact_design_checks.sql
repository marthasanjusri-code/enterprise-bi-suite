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

-- Result (01 Nov 2026): 280 sold in Northwest 2022-05-30 to 2025-04-30
-- (95 orders) despite territory history ending 2023-09-29. 284 sold in
-- Northwest from 2023-09-30 (140 orders). Both quotas belong to Northwest.
-- Territory rule: covering period > nearest period > region from orders.


-- =====================================================================
-- fact_finance: grain, dates, hierarchy levels (DW source)
-- =====================================================================

USE AdventureWorksDW2025;
GO

-- 1. Grain: is each date + organization + department group + scenario
--    + account combination unique?
SELECT  COUNT(*) AS finance_rows,
        COUNT(DISTINCT CONCAT(DateKey, '|', OrganizationKey, '|', DepartmentGroupKey,
                              '|', ScenarioKey, '|', AccountKey)) AS distinct_combinations
FROM dbo.FactFinance;

-- 2. Dates: one date per month? After the +4,170 day shift, does any
--    month get two dates or lose its date?
SELECT  CAST([Date] AS date)                     AS source_date,
        CAST(DATEADD(day, 4170, [Date]) AS date) AS shifted_date,
        COUNT(*)                                 AS finance_rows
FROM dbo.FactFinance
GROUP BY [Date]
ORDER BY [Date];

SELECT  COUNT(*)                                     AS shifted_months,
        SUM(CASE WHEN dates_in_month > 1 THEN 1 ELSE 0 END) AS months_with_two_dates
FROM (
    SELECT  YEAR(DATEADD(day, 4170, [Date]))  AS yr,
            MONTH(DATEADD(day, 4170, [Date])) AS mo,
            COUNT(DISTINCT [Date])            AS dates_in_month
    FROM dbo.FactFinance
    GROUP BY YEAR(DATEADD(day, 4170, [Date])), MONTH(DATEADD(day, 4170, [Date]))
) m;

-- 3. Account hierarchy with fact rows per account. If parent accounts
--    also hold amounts, adding up the hierarchy would double count.
WITH h AS (
    SELECT  AccountKey, ParentAccountKey, AccountType, Operator, ValueType,
            0 AS lvl,
            CAST(AccountDescription AS nvarchar(200))  AS account_name,
            CAST(RIGHT('0000' + CAST(AccountKey AS varchar(10)), 4) AS varchar(400)) AS sort_path
    FROM dbo.DimAccount
    WHERE ParentAccountKey IS NULL
    UNION ALL
    SELECT  a.AccountKey, a.ParentAccountKey, a.AccountType, a.Operator, a.ValueType,
            h.lvl + 1,
            CAST(a.AccountDescription AS nvarchar(200)),
            CAST(h.sort_path + '.' + RIGHT('0000' + CAST(a.AccountKey AS varchar(10)), 4) AS varchar(400))
    FROM dbo.DimAccount a
    JOIN h ON a.ParentAccountKey = h.AccountKey
)
SELECT  h.lvl,
        REPLICATE('    ', h.lvl) + h.account_name                    AS account,
        h.AccountKey,
        h.AccountType,
        h.Operator,
        h.ValueType,
        (SELECT COUNT(*) FROM dbo.DimAccount c
          WHERE c.ParentAccountKey = h.AccountKey)                   AS child_accounts,
        (SELECT COUNT(*) FROM dbo.FactFinance f
          WHERE f.AccountKey = h.AccountKey)                         AS fact_rows
FROM h
ORDER BY h.sort_path;

-- 4. Organizations and department groups: do parent levels hold rows?
SELECT  'organization'  AS dimension,
        o.OrganizationKey AS member_key,
        o.OrganizationName AS member_name,
        (SELECT COUNT(*) FROM dbo.DimOrganization c
          WHERE c.ParentOrganizationKey = o.OrganizationKey) AS children,
        (SELECT COUNT(*) FROM dbo.FactFinance f
          WHERE f.OrganizationKey = o.OrganizationKey)       AS fact_rows
FROM dbo.DimOrganization o
UNION ALL
SELECT  'department group',
        g.DepartmentGroupKey,
        g.DepartmentGroupName,
        (SELECT COUNT(*) FROM dbo.DimDepartmentGroup c
          WHERE c.ParentDepartmentGroupKey = g.DepartmentGroupKey),
        (SELECT COUNT(*) FROM dbo.FactFinance f
          WHERE f.DepartmentGroupKey = g.DepartmentGroupKey)
FROM dbo.DimDepartmentGroup g
ORDER BY dimension, member_key;
GO

-- Results (01 Nov 2026):
--   1. 39,409 rows = 39,409 distinct combinations. Grain confirmed.
--   3. 99 accounts. Every account with children has 0 fact rows; amounts
--      sit only on leaf accounts. Tree: Balance Sheet (Assets; Liabilities
--      and Owners Equity, operator '-'), Net Income > Operating Profit >
--      Gross Margin > Net Sales, Total Cost of Sales ('-'), Operating
--      Expenses ('-'), Other Income and Expense, Taxes ('-'), and
--      Statistical Accounts (Headcount, Units, Square Footage: Units).
--   4. Organizations: only the 9 leaf units hold rows.
--      Department groups: Corporate (parent of the other 6) holds 8,843
--      rows itself. Needs a check: own amounts or totals of children?


-- =====================================================================
-- fact_finance: Corporate department group (parent with its own rows)
-- =====================================================================

-- A. Which kind of accounts does each department group hold?
--    (Top-level account: Balance Sheet, Net Income or Statistical.)
WITH h AS (
    SELECT AccountKey, AccountKey AS top_key
    FROM dbo.DimAccount WHERE ParentAccountKey IS NULL
    UNION ALL
    SELECT a.AccountKey, h.top_key
    FROM dbo.DimAccount a JOIN h ON a.ParentAccountKey = h.AccountKey
)
SELECT  g.DepartmentGroupName,
        t.AccountDescription AS top_level_account,
        COUNT(*)             AS finance_rows
FROM dbo.FactFinance f
JOIN dbo.DimDepartmentGroup g ON g.DepartmentGroupKey = f.DepartmentGroupKey
JOIN h                        ON h.AccountKey         = f.AccountKey
JOIN dbo.DimAccount t         ON t.AccountKey         = h.top_key
GROUP BY g.DepartmentGroupName, t.AccountDescription
ORDER BY g.DepartmentGroupName, t.AccountDescription;

-- B. Does any Corporate row repeat a child group's row for the same
--    date, organization, scenario and account? If yes, compare amounts:
--    equal to the children's total = a subtotal (double counting risk).
WITH corp AS (
    SELECT DateKey, OrganizationKey, ScenarioKey, AccountKey, Amount
    FROM dbo.FactFinance WHERE DepartmentGroupKey = 1
),
kids AS (
    SELECT DateKey, OrganizationKey, ScenarioKey, AccountKey, SUM(Amount) AS amount
    FROM dbo.FactFinance WHERE DepartmentGroupKey <> 1
    GROUP BY DateKey, OrganizationKey, ScenarioKey, AccountKey
)
SELECT  COUNT(*)                                                       AS overlapping_combinations,
        SUM(CASE WHEN ABS(c.Amount - k.amount) < 0.01 THEN 1 ELSE 0 END) AS corporate_equals_children
FROM corp c
JOIN kids k
  ON k.DateKey = c.DateKey AND k.OrganizationKey = c.OrganizationKey
 AND k.ScenarioKey = c.ScenarioKey AND k.AccountKey = c.AccountKey;
GO

-- Results (01 Nov 2026):
--   A. Corporate holds Net Income 8,567 and Statistical 276 rows, no
--      Balance Sheet. Balance Sheet sits in Sales and Marketing (7,776),
--      Executive General and Administration (276), Inventory Management (72).
--   B. All 8,843 Corporate rows overlap a child row; only 342 equal the
--      children's total.

-- C. Are the 342 equal rows just zeros? And is Corporate usually larger
--    than its children (which would suggest "own + children")?
-- Result (01 Nov 2026): 342 equal (not zero), 4,023 Corporate larger,
-- 4,478 Corporate smaller. Corporate is its own data, not a subtotal and
-- not "own + children". Keep all rows; model as "Corporate (direct)".
WITH corp AS (
    SELECT DateKey, OrganizationKey, ScenarioKey, AccountKey, Amount
    FROM dbo.FactFinance WHERE DepartmentGroupKey = 1
),
kids AS (
    SELECT DateKey, OrganizationKey, ScenarioKey, AccountKey, SUM(Amount) AS amount
    FROM dbo.FactFinance WHERE DepartmentGroupKey <> 1
    GROUP BY DateKey, OrganizationKey, ScenarioKey, AccountKey
)
SELECT  CASE WHEN ABS(c.Amount - k.amount) < 0.01 AND c.Amount = 0 THEN 'equal, both zero'
             WHEN ABS(c.Amount - k.amount) < 0.01                   THEN 'equal, not zero'
             WHEN c.Amount > k.amount                               THEN 'corporate larger'
             ELSE                                                        'corporate smaller'
        END      AS comparison,
        COUNT(*) AS combinations
FROM corp c
JOIN kids k
  ON k.DateKey = c.DateKey AND k.OrganizationKey = c.OrganizationKey
 AND k.ScenarioKey = c.ScenarioKey AND k.AccountKey = c.AccountKey
GROUP BY CASE WHEN ABS(c.Amount - k.amount) < 0.01 AND c.Amount = 0 THEN 'equal, both zero'
              WHEN ABS(c.Amount - k.amount) < 0.01                   THEN 'equal, not zero'
              WHEN c.Amount > k.amount                               THEN 'corporate larger'
              ELSE                                                        'corporate smaller'
         END;
GO

-- D. The 342 equal combinations: how many child rows, which accounts?
-- Result (01 Nov 2026): spread over 22 accounts; 230 match one child row,
-- 112 match the sum of two children (rules out simple copies). 0.9% of
-- finance rows. Decision: keep; report the count in a data quality check;
-- in a real company, confirm with the finance team.
WITH corp AS (
    SELECT DateKey, OrganizationKey, ScenarioKey, AccountKey, Amount
    FROM dbo.FactFinance WHERE DepartmentGroupKey = 1
),
kids AS (
    SELECT DateKey, OrganizationKey, ScenarioKey, AccountKey,
           SUM(Amount) AS amount, COUNT(*) AS child_rows
    FROM dbo.FactFinance WHERE DepartmentGroupKey <> 1
    GROUP BY DateKey, OrganizationKey, ScenarioKey, AccountKey
)
SELECT  a.AccountDescription,
        k.child_rows,
        COUNT(*) AS combinations
FROM corp c
JOIN kids k
  ON k.DateKey = c.DateKey AND k.OrganizationKey = c.OrganizationKey
 AND k.ScenarioKey = c.ScenarioKey AND k.AccountKey = c.AccountKey
JOIN dbo.DimAccount a ON a.AccountKey = c.AccountKey
WHERE ABS(c.Amount - k.amount) < 0.01
GROUP BY a.AccountDescription, k.child_rows
ORDER BY combinations DESC;
GO