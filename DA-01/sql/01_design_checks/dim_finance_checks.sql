/*
  dim_finance_checks.sql
  Design checks for the finance dimensions: dw.dim_account (signs and
  levels), dw.dim_organization (hierarchy shape) and a test of the sign
  logic on real amounts, including whether balance sheet rows are
  balances or monthly movements.

  Source: AdventureWorksDW2025. Read-only (uses one temporary table).
  Each check is followed or preceded by its result and the decision it supports.
*/

USE AdventureWorksDW2025;
GO

-- =====================================================================
-- dim_account: the sign of every leaf account towards every ancestor
-- =====================================================================

-- A node's value = sum of its children, each times the child's operator
-- ('+' = 1, '-' = -1, '~' = 0, not added). So a leaf's sign towards an
-- ancestor is the product of the operators on the path between them.
-- Built once into a temporary table and reused by the checks below.
IF OBJECT_ID('tempdb..#account_signs') IS NOT NULL DROP TABLE #account_signs;

WITH up AS (
    SELECT  a.AccountKey          AS leaf_key,
            a.AccountKey          AS ancestor_key,
            a.ParentAccountKey    AS next_parent,
            CAST(1 AS int)        AS sign,
            CASE a.Operator WHEN '+' THEN 1 WHEN '-' THEN -1 ELSE 0 END AS op,
            0                     AS steps
    FROM dbo.DimAccount a
    WHERE NOT EXISTS (SELECT 1 FROM dbo.DimAccount c WHERE c.ParentAccountKey = a.AccountKey)
    UNION ALL
    SELECT  u.leaf_key,
            p.AccountKey,
            p.ParentAccountKey,
            u.sign * u.op,
            CASE p.Operator WHEN '+' THEN 1 WHEN '-' THEN -1 ELSE 0 END,
            u.steps + 1
    FROM up u
    JOIN dbo.DimAccount p ON p.AccountKey = u.next_parent
)
SELECT leaf_key, ancestor_key, sign, steps
INTO #account_signs
FROM up;

-- 1. Depth of the tree and how leaves roll into the four profit lines
--    (Net Sales 50, Gross Margin 49, Operating Profit 48, Net Income 47).
SELECT  a.AccountDescription                     AS profit_line,
        s.ancestor_key,
        COUNT(*)                                 AS leaf_accounts,
        SUM(CASE WHEN s.sign =  1 THEN 1 ELSE 0 END) AS added,
        SUM(CASE WHEN s.sign = -1 THEN 1 ELSE 0 END) AS subtracted,
        SUM(CASE WHEN s.sign =  0 THEN 1 ELSE 0 END) AS ignored,
        MAX(s.steps)                             AS max_depth_below
FROM #account_signs s
JOIN dbo.DimAccount a ON a.AccountKey = s.ancestor_key
WHERE s.ancestor_key IN (47, 48, 49, 50)
GROUP BY a.AccountDescription, s.ancestor_key
ORDER BY s.ancestor_key DESC;

-- 2. Plausibility on real amounts (Actual, USD organizations only, so no
--    currency mixing): margins should fall between 0% and 100%.
SELECT  YEAR(f.[Date])                                                         AS dw_year,
        CAST(SUM(CASE WHEN s.ancestor_key = 50 THEN f.Amount * s.sign END) AS decimal(18,0)) AS net_sales,
        CAST(SUM(CASE WHEN s.ancestor_key = 49 THEN f.Amount * s.sign END) AS decimal(18,0)) AS gross_margin,
        CAST(SUM(CASE WHEN s.ancestor_key = 48 THEN f.Amount * s.sign END) AS decimal(18,0)) AS operating_profit,
        CAST(SUM(CASE WHEN s.ancestor_key = 47 THEN f.Amount * s.sign END) AS decimal(18,0)) AS net_income
FROM dbo.FactFinance f
JOIN #account_signs s    ON s.leaf_key = f.AccountKey
JOIN dbo.DimScenario sc  ON sc.ScenarioKey = f.ScenarioKey
JOIN dbo.DimOrganization o ON o.OrganizationKey = f.OrganizationKey
JOIN dbo.DimCurrency c   ON c.CurrencyKey = o.CurrencyKey
WHERE sc.ScenarioName = 'Actual'
  AND c.CurrencyAlternateKey = 'USD'
GROUP BY YEAR(f.[Date])
ORDER BY dw_year;

-- 3. Balance sheet: are the rows month-end BALANCES or monthly MOVEMENTS?
--    Balances: assets should equal liabilities + equity in each month.
--    Movements: only the running totals would balance.
--    (Assets = account 2, Liabilities and Owners Equity = account 25.)
WITH monthly AS (
    SELECT  EOMONTH(f.[Date])                                              AS month_end,
            SUM(CASE WHEN s.ancestor_key = 2  THEN f.Amount * s.sign END)  AS assets,
            SUM(CASE WHEN s.ancestor_key = 25 THEN f.Amount * s.sign END)  AS liabilities_equity
    FROM dbo.FactFinance f
    JOIN #account_signs s      ON s.leaf_key = f.AccountKey
    JOIN dbo.DimScenario sc    ON sc.ScenarioKey = f.ScenarioKey
    JOIN dbo.DimOrganization o ON o.OrganizationKey = f.OrganizationKey
    JOIN dbo.DimCurrency c     ON c.CurrencyKey = o.CurrencyKey
    WHERE sc.ScenarioName = 'Actual'
      AND c.CurrencyAlternateKey = 'USD'
    GROUP BY EOMONTH(f.[Date])
)
SELECT  month_end,
        CAST(assets AS decimal(18,0))                                   AS assets,
        CAST(liabilities_equity AS decimal(18,0))                       AS liabilities_equity,
        CAST(assets - liabilities_equity AS decimal(18,0))              AS difference,
        CAST(SUM(assets) OVER (ORDER BY month_end)
           - SUM(liabilities_equity) OVER (ORDER BY month_end) AS decimal(18,0)) AS running_difference
FROM monthly
ORDER BY month_end;

-- =====================================================================
-- dim_organization: shape of the hierarchy
-- =====================================================================

-- 4. Path and depth of every organization unit (ragged or even?).
WITH h AS (
    SELECT  OrganizationKey, ParentOrganizationKey, 0 AS lvl,
            CAST(OrganizationName AS nvarchar(400)) AS org_path
    FROM dbo.DimOrganization
    WHERE ParentOrganizationKey IS NULL
    UNION ALL
    SELECT  o.OrganizationKey, o.ParentOrganizationKey, h.lvl + 1,
            CAST(h.org_path + ' > ' + o.OrganizationName AS nvarchar(400))
    FROM dbo.DimOrganization o
    JOIN h ON o.ParentOrganizationKey = h.OrganizationKey
)
SELECT  lvl, org_path,
        CASE WHEN EXISTS (SELECT 1 FROM dbo.DimOrganization c
                          WHERE c.ParentOrganizationKey = h.OrganizationKey)
             THEN 'parent' ELSE 'leaf' END AS node_type
FROM h
ORDER BY org_path;

-- Results (03 Nov 2026):
--   1. Net Sales: 4 leaves, 2 added (sales), 2 subtracted (returns,
--      discounts). Gross Margin: 6 leaves, 2 added, 4 subtracted (also
--      standard cost, variances). Operating Profit: 29, 2 added, 27
--      subtracted. Net Income: 35, 6 added, 29 subtracted. Max depth 5.
--   2. Actual, USD units (DW years): 2011 net sales 17.46 M, gross margin
--      67.0%, operating margin 28.1%, net margin 21.6%; 2012 69.7% / 26.8% /
--      19.5%; 2013 69.1% / 24.7% / 19.3%. 2010 holds only December (one
--      month), so its negative profit is a partial-period effect.
--      Sign logic confirmed: sales add, costs subtract, margins sensible
--      and stable.

-- Results (03 Nov 2026):
--   1. Net Sales: 4 leaves, 2 added, 2 subtracted (returns, discounts).
--      Gross Margin: 6 leaves, 2 added, 4 subtracted. Operating Profit: 29
--      leaves, 2 added, 27 subtracted. Net Income: 35 leaves, 6 added
--      (sales, interest income, gains, other income, exchange gains),
--      29 subtracted. Max depth 5 below Net Income. Sign logic correct.
--   2. USD units, Actual: 2011 net sales 17.46 M, gross margin 67.0%,
--      operating margin 28.1%, net margin 21.6%. 2012: 69.7% / 26.8% /
--      19.5%. 2013: 69.1% / 24.7% / 19.3%. 2010 is one month only.
--      Margins sensible and in the right order.
--   3. Assets = liabilities + equity in every month (difference 0).
--      This proves the signs, but does NOT tell balances from movements:
--      under double-entry, monthly movements also balance.
--      Also: this check grouped by the ORIGINAL month, which merged the
--      late month-ends (2011-03-01 is February's) into the next month.
--      The design groups by the SHIFTED month, where they separate.
--   4. Organization tree is ragged: France, Germany, Canadian Division,
--      Australia are leaves at level 2; the 5 US divisions at level 3
--      under USA Operations.


-- 3b. Balances or movements? Repeat the monthly totals on the SHIFTED
--     month (as the design will), and look at how fixed-asset accounts
--     behave. Balances of land and buildings stay positive and fairly
--     stable; movements are mostly zero and can be negative.
SELECT  EOMONTH(DATEADD(day, 4170, f.[Date]))                               AS shifted_month_end,
        CAST(SUM(CASE WHEN s.ancestor_key = 2  THEN f.Amount * s.sign END) AS decimal(18,0)) AS assets,
        CAST(SUM(CASE WHEN s.ancestor_key = 25 THEN f.Amount * s.sign END) AS decimal(18,0)) AS liabilities_equity
FROM dbo.FactFinance f
JOIN #account_signs s      ON s.leaf_key = f.AccountKey
JOIN dbo.DimScenario sc    ON sc.ScenarioKey = f.ScenarioKey
JOIN dbo.DimOrganization o ON o.OrganizationKey = f.OrganizationKey
JOIN dbo.DimCurrency c     ON c.CurrencyKey = o.CurrencyKey
WHERE sc.ScenarioName = 'Actual'
  AND c.CurrencyAlternateKey = 'USD'
GROUP BY EOMONTH(DATEADD(day, 4170, f.[Date]))
ORDER BY shifted_month_end;

SELECT  a.AccountKey,
        a.AccountDescription,
        COUNT(*)                                          AS rows,
        SUM(CASE WHEN f.Amount < 0 THEN 1 ELSE 0 END)     AS negative_rows,
        SUM(CASE WHEN f.Amount = 0 THEN 1 ELSE 0 END)     AS zero_rows,
        CAST(MIN(f.Amount) AS decimal(18,0))              AS min_amount,
        CAST(MAX(f.Amount) AS decimal(18,0))              AS max_amount
FROM dbo.FactFinance f
JOIN dbo.DimAccount a   ON a.AccountKey = f.AccountKey
JOIN dbo.DimScenario sc ON sc.ScenarioKey = f.ScenarioKey
WHERE sc.ScenarioName = 'Actual'
  AND f.AccountKey IN (4, 6, 18, 19, 20, 21)   -- Cash, Trade Receivables, Land, Buildings, Machinery, Office Furniture
GROUP BY a.AccountKey, a.AccountDescription
ORDER BY a.AccountKey;

DROP TABLE #account_signs;
GO

-- Results (03 Nov 2026), check 3b:
--   By shifted month, assets = liabilities + equity in all 36 months from
--   May 2022 to April 2025, with no doubled months. May 2025 has NO
--   balance sheet rows (income statement only).
--   Cash, Trade Receivables, Land, Buildings, Machinery and Office
--   Furniture: 276 rows each, 0 negative, 0 zero. Land and buildings are
--   positive every month: the rows are month-end BALANCES, not movements.
-- Decisions:
--   - Balance sheet measures use the closing balance of the last month in
--     the selection that HAS balance sheet rows (latest = April 2025).
--   - dim_account: account code and name, account type, operator, value
--     type, statement (Income statement / Balance sheet / Statistical),
--     sign_to_net_income (+1 / -1 / 0), levels 1-6 flattened with the leaf
--     name repeated in empty levels, sort order from the tree path.
--   - dim_organization: levels 1-3 flattened (leaf name repeated),
--     region_group from level 1 (North America / Europe / Pacific),
--     mapped sales territory for leaf units, currency code.
--   - dim_finance_department_group: level 1 "Corporate", level 2 = group
--     name, plus member "Corporate (direct)" for Corporate's own rows.
--   - dim_scenario: Actual, Budget, Forecast (kept, no rows yet).

-- =====================================================================
-- dim_account: operators inside the balance sheet
-- =====================================================================
-- 5. Does any balance sheet account subtract (operator "-")? If so, balance
--    sheet totals would need their own sign column, like sign_to_net_income.
-- Result (10 Nov 2026):
--   Balance Sheet: "-" 1 account (20 Liabilities and Owners Equity),
--   "~" 1 (1 Balance Sheet itself), "+" 44 (all others, including
--   1150 Allowance for Bad Debt). Net Income: "-" 6, "+" 42.
--   Statistical Accounts: "~" 5.
-- Decision (D97): no balance sheet sign column. Totals are taken within
--   Assets or within Liabilities and Owners Equity, never across them.
WITH t AS (
    SELECT AccountKey, ParentAccountKey, AccountCodeAlternateKey, AccountDescription, Operator,
           CAST(AccountDescription AS nvarchar(200)) AS top_account
    FROM AdventureWorksDW2025.dbo.DimAccount WHERE ParentAccountKey IS NULL
    UNION ALL
    SELECT c.AccountKey, c.ParentAccountKey, c.AccountCodeAlternateKey, c.AccountDescription, c.Operator, t.top_account
    FROM t JOIN AdventureWorksDW2025.dbo.DimAccount c ON c.ParentAccountKey = t.AccountKey
)
SELECT top_account, Operator, COUNT(*) AS accounts,
       STRING_AGG(CAST(AccountCodeAlternateKey AS varchar(10)) + ' ' + AccountDescription, '; ') AS which
FROM t
GROUP BY top_account, Operator
ORDER BY top_account, Operator;
