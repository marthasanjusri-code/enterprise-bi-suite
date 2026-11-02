/*
  fact_finance_checks.sql
  Design checks for dw.fact_finance (one row per month, organization,
  department group, account, scenario and entry type): grain, monthly
  dates after the shift, hierarchies, the Corporate group, and currency.

  Source: AdventureWorksDW2025. Read-only.
  Each check is followed or preceded by its result and the decision it supports.
*/

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

-- Result (02 Nov 2026): 39 source dates; after the shift they fall in
-- 37 months, and 2 months contain two dates.

-- 2c. Is the "two dates in one month" caused by our shift, or is it
--     already in the source? Count months before shifting, then list the
--     dates in any month that has more than one.
SELECT  COUNT(DISTINCT [Date])                           AS source_dates,
        COUNT(DISTINCT YEAR([Date]) * 100 + MONTH([Date])) AS source_months
FROM dbo.FactFinance;

WITH multi AS (
    SELECT YEAR([Date]) AS yr, MONTH([Date]) AS mo
    FROM dbo.FactFinance
    GROUP BY YEAR([Date]), MONTH([Date])
    HAVING COUNT(DISTINCT [Date]) > 1
)
SELECT  CAST(f.[Date] AS date)                     AS source_date,
        CAST(DATEADD(day, 4170, f.[Date]) AS date) AS shifted_date,
        s.ScenarioName,
        COUNT(*)                                   AS finance_rows
FROM dbo.FactFinance f
JOIN dbo.DimScenario s ON s.ScenarioKey = f.ScenarioKey
JOIN multi m ON m.yr = YEAR(f.[Date]) AND m.mo = MONTH(f.[Date])
GROUP BY f.[Date], s.ScenarioName
ORDER BY f.[Date], s.ScenarioName;

-- Result (02 Nov 2026): 39 source dates in 34 source months, so the
-- source itself has 5 months with two dates:
--   2011-03-01/03-31, 2011-05-01/05-31, 2011-08-01/08-29 (full Actual and
--   Budget sets on both; the 1st-of-month dates are late month-ends) and
--   2011-12-28/29, 2012-12-27/28 (small year-end sets of 18 and 28 rows).
-- After +4,170 days the first three pairs fall in separate months; only the
-- two year-end pairs share a month. Shifted range May 2022 to May 2025 =
-- 37 months, every month covered. Plan: finance grain = month, with
-- period date = EOMONTH(shifted date), so each month has one date.

-- 2d. With one date per month, would any rows collide on the same
--     month + organization + department group + scenario + account?
--     Collisions must be summed during the load.
WITH m AS (
    SELECT  EOMONTH(DATEADD(day, 4170, [Date])) AS period_end,
            OrganizationKey, DepartmentGroupKey, ScenarioKey, AccountKey,
            COUNT(*) AS rows_in_period
    FROM dbo.FactFinance
    GROUP BY EOMONTH(DATEADD(day, 4170, [Date])),
             OrganizationKey, DepartmentGroupKey, ScenarioKey, AccountKey
)
SELECT  COUNT(*)                                            AS monthly_combinations,
        SUM(CASE WHEN rows_in_period > 1 THEN 1 ELSE 0 END) AS combinations_with_two_rows,
        COUNT(DISTINCT period_end)                          AS periods
FROM m;

-- Result (02 Nov 2026): 39,403 monthly combinations, 6 with two rows,
-- 37 periods. The 6 collisions can only occur in the two year-end months
-- (the only months that still hold two dates after the shift), so each is
-- a main row plus a year-end adjustment row.
-- Decision: period date = EOMONTH(shifted date); keep both rows, marked by
-- entry_type 'Regular' / 'Year-end adjustment'. Grain stays unique.

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


-- =====================================================================
-- fact_finance: are amounts in local currency or USD?
-- =====================================================================

-- Compare each organization's finance Gross Sales (Actual) with the
-- sales of its matching territory in the DW sales tables (stored in USD),
-- over the same window (DW timeline, 2011-2013).
-- If finance is in USD, the ratio is similar for every organization.
-- If finance is in local currency, EUR organizations show a clearly
-- different ratio (EUR was worth more than USD in those years).
-- AUD and CAD were close to USD then, so EUR is the deciding test.
-- AccountKey 51 = Gross Sales (from the account tree, check 3).
WITH fin AS (
    SELECT  CASE o.OrganizationName
                 WHEN 'Canadian Division' THEN 'Canada'
                 ELSE REPLACE(o.OrganizationName, ' Division', '')
            END                   AS region,
            c.CurrencyAlternateKey AS org_currency,
            SUM(f.Amount)          AS finance_gross_sales
    FROM dbo.FactFinance f
    JOIN dbo.DimOrganization o ON o.OrganizationKey = f.OrganizationKey
    JOIN dbo.DimCurrency c     ON c.CurrencyKey     = o.CurrencyKey
    JOIN dbo.DimScenario s     ON s.ScenarioKey     = f.ScenarioKey
    WHERE s.ScenarioName = 'Actual'
      AND f.AccountKey IN (SELECT AccountKey FROM dbo.DimAccount WHERE ParentAccountKey = 51)
      AND f.[Date] >= '2011-01-01' AND f.[Date] < '2014-01-01'
    GROUP BY o.OrganizationName, c.CurrencyAlternateKey
),
sales AS (
    SELECT  t.SalesTerritoryRegion AS region,
            SUM(x.SalesAmount)     AS sales_usd
    FROM (SELECT SalesTerritoryKey, SalesAmount, OrderDate FROM dbo.FactInternetSales
          UNION ALL
          SELECT SalesTerritoryKey, SalesAmount, OrderDate FROM dbo.FactResellerSales) x
    JOIN dbo.DimSalesTerritory t ON t.SalesTerritoryKey = x.SalesTerritoryKey
    WHERE x.OrderDate >= '2011-01-01' AND x.OrderDate < '2014-01-01'
    GROUP BY t.SalesTerritoryRegion
)
SELECT  fin.region,
        fin.org_currency,
        CAST(fin.finance_gross_sales AS decimal(18,0))                     AS finance_gross_sales,
        CAST(sales.sales_usd AS decimal(18,0))                             AS territory_sales_usd,
        CAST(fin.finance_gross_sales / NULLIF(sales.sales_usd, 0) AS decimal(10,3)) AS finance_to_sales_ratio
FROM fin
LEFT JOIN sales ON sales.region = fin.region
ORDER BY fin.org_currency, fin.region;

-- Average exchange rates in the same window, for reference.
SELECT  c.CurrencyAlternateKey AS currency,
        CAST(AVG(r.AverageRate) AS decimal(10,4)) AS avg_rate
FROM dbo.FactCurrencyRate r
JOIN dbo.DimCurrency c ON c.CurrencyKey = r.CurrencyKey
WHERE c.CurrencyAlternateKey IN ('EUR', 'AUD', 'CAD', 'GBP')
  AND r.[Date] >= '2011-01-01' AND r.[Date] < '2014-01-01'
GROUP BY c.CurrencyAlternateKey;
GO

-- Result (02 Nov 2026): finance-to-sales ratio varies widely even among USD
-- organizations (Northwest 0.750 to Central 1.717); EUR organizations
-- (France 0.869, Germany 0.566) fall inside that range. Finance gross sales
-- do not track territory sales per organization, so this test cannot decide
-- the currency. Across all 9 organizations, finance gross sales (107.8 M)
-- are within about 6% of territory sales (101.6 M, UK excluded).
-- Average rates in the DW are synthetic (EUR 0.922, AUD 0.551, CAD 0.654,
-- GBP 1.488) and do not match real-world rates.
-- F8 finding: finance and sales agree roughly in total, not per organization.

-- Currency evidence 2: exchange gains and losses (account 93) only arise
-- when a unit works in a currency other than the reporting currency.
-- If they appear only for non-USD organizations, finance amounts are in
-- local currency.
SELECT  o.OrganizationName,
        c.CurrencyAlternateKey      AS org_currency,
        s.ScenarioName,
        COUNT(*)                    AS rows,
        CAST(SUM(f.Amount) AS decimal(18,2)) AS amount
FROM dbo.FactFinance f
JOIN dbo.DimOrganization o ON o.OrganizationKey = f.OrganizationKey
JOIN dbo.DimCurrency c     ON c.CurrencyKey     = o.CurrencyKey
JOIN dbo.DimScenario s     ON s.ScenarioKey     = f.ScenarioKey
WHERE f.AccountKey = 93
GROUP BY o.OrganizationName, c.CurrencyAlternateKey, s.ScenarioName
ORDER BY org_currency, o.OrganizationName;
GO
-- Result (02 Nov 2026): account 93 has rows for all 9 organizations,
-- USD ones included (3 rows each for US divisions). Exchange differences
-- in USD units do not prove local currency for the others, so the test is
-- inconclusive.
-- Decision: treat finance amounts as the reporting currency (USD).
--   No evidence of local currency; DW rates are synthetic, so converting
--   would add invented distortion; company-level finance sales are within
--   about 6% of USD sales. Organization currency is kept in
--   dim_organization so a conversion step can be added later. The
--   assumption is shown on the finance page and listed as a limitation.


-- =====================================================================
-- fact_finance: currency evidence 3, unit-cost ratios
-- =====================================================================

-- Money divided by a non-money quantity gives a "price" that should be
-- similar across organizations if all amounts share one currency:
--   salaries per head   = Salaries (60) / Headcount (96)
--   rent per square foot = Rent (87)     / Square Footage (99)
-- If non-USD organizations differ from the USD ones by about their
-- exchange rate (EUR 0.922, AUD 0.551, CAD 0.654, or the inverse),
-- amounts are in local currency. If they match the USD ones, amounts are
-- in USD. If the USD organizations themselves are widely spread, the test
-- cannot decide.
WITH monthly AS (
    SELECT  f.OrganizationKey,
            f.[Date],
            SUM(CASE WHEN f.AccountKey = 60 THEN f.Amount END) AS salaries,
            SUM(CASE WHEN f.AccountKey = 96 THEN f.Amount END) AS headcount,
            SUM(CASE WHEN f.AccountKey = 87 THEN f.Amount END) AS rent,
            SUM(CASE WHEN f.AccountKey = 99 THEN f.Amount END) AS square_feet
    FROM dbo.FactFinance f
    JOIN dbo.DimScenario s ON s.ScenarioKey = f.ScenarioKey
    WHERE s.ScenarioName = 'Actual'
    GROUP BY f.OrganizationKey, f.[Date]
)
SELECT  o.OrganizationName,
        c.CurrencyAlternateKey                                         AS org_currency,
        CAST(AVG(salaries / NULLIF(headcount, 0))  AS decimal(12,2))    AS salaries_per_head,
        CAST(AVG(rent / NULLIF(square_feet, 0))    AS decimal(12,4))    AS rent_per_square_foot,
        COUNT(salaries / NULLIF(headcount, 0))                          AS months_with_both
FROM monthly m
JOIN dbo.DimOrganization o ON o.OrganizationKey = m.OrganizationKey
JOIN dbo.DimCurrency c     ON c.CurrencyKey     = o.CurrencyKey
GROUP BY o.OrganizationName, c.CurrencyAlternateKey
ORDER BY org_currency, o.OrganizationName;
GO
-- Result (02 Nov 2026), salaries per head / rent per square foot:
--   USD divisions: 2,320-5,011 / 0.030-0.064
--   Australia (AUD) 8,069 / 0.224 and Canada (CAD) 7,505 / 0.085 are ABOVE
--   the whole USD range on BOTH measures. France and Germany (EUR, rate near
--   1) fall inside the USD range.
-- Reading: AUD and CAD amounts are inflated by roughly the inverse of their
-- rates (AUD 0.551, CAD 0.654 USD per unit). Finance amounts are in local
-- currency. AverageRate = USD per 1 unit, so USD = local amount x rate.


-- =====================================================================
-- fact_finance: test the conversion before adopting it
-- =====================================================================

-- A. Does every non-USD finance month have an exchange rate?
WITH rates AS (
    SELECT  CurrencyKey,
            EOMONTH([Date])  AS rate_month,
            AVG(AverageRate) AS avg_rate
    FROM dbo.FactCurrencyRate
    GROUP BY CurrencyKey, EOMONTH([Date])
)
SELECT  c.CurrencyAlternateKey                                AS org_currency,
        COUNT(*)                                              AS finance_rows,
        SUM(CASE WHEN r.avg_rate IS NULL THEN 1 ELSE 0 END)   AS rows_without_rate
FROM dbo.FactFinance f
JOIN dbo.DimOrganization o ON o.OrganizationKey = f.OrganizationKey
JOIN dbo.DimCurrency c     ON c.CurrencyKey     = o.CurrencyKey
LEFT JOIN rates r          ON r.CurrencyKey     = o.CurrencyKey
                          AND r.rate_month      = EOMONTH(f.[Date])
GROUP BY c.CurrencyAlternateKey
ORDER BY org_currency;

-- B. After converting with the monthly average rate (USD rows keep 1.0),
--    non-USD organizations should move INTO the USD range.
WITH rates AS (
    SELECT  CurrencyKey,
            EOMONTH([Date])  AS rate_month,
            AVG(AverageRate) AS avg_rate
    FROM dbo.FactCurrencyRate
    GROUP BY CurrencyKey, EOMONTH([Date])
),
monthly AS (
    SELECT  f.OrganizationKey,
            f.[Date],
            SUM(CASE WHEN f.AccountKey = 60
                     THEN f.Amount * CASE WHEN c.CurrencyAlternateKey = 'USD' THEN 1 ELSE r.avg_rate END
                END) AS salaries_usd,
            SUM(CASE WHEN f.AccountKey = 96 THEN f.Amount END) AS headcount,
            SUM(CASE WHEN f.AccountKey = 87
                     THEN f.Amount * CASE WHEN c.CurrencyAlternateKey = 'USD' THEN 1 ELSE r.avg_rate END
                END) AS rent_usd,
            SUM(CASE WHEN f.AccountKey = 99 THEN f.Amount END) AS square_feet
    FROM dbo.FactFinance f
    JOIN dbo.DimScenario s     ON s.ScenarioKey     = f.ScenarioKey
    JOIN dbo.DimOrganization o ON o.OrganizationKey = f.OrganizationKey
    JOIN dbo.DimCurrency c     ON c.CurrencyKey     = o.CurrencyKey
    LEFT JOIN rates r          ON r.CurrencyKey     = o.CurrencyKey
                              AND r.rate_month      = EOMONTH(f.[Date])
    WHERE s.ScenarioName = 'Actual'
    GROUP BY f.OrganizationKey, f.[Date]
)
SELECT  o.OrganizationName,
        c.CurrencyAlternateKey                                       AS org_currency,
        CAST(AVG(salaries_usd / NULLIF(headcount, 0)) AS decimal(12,2)) AS salaries_per_head_usd,
        CAST(AVG(rent_usd / NULLIF(square_feet, 0))   AS decimal(12,4)) AS rent_per_square_foot_usd
FROM monthly m
JOIN dbo.DimOrganization o ON o.OrganizationKey = m.OrganizationKey
JOIN dbo.DimCurrency c     ON c.CurrencyKey     = o.CurrencyKey
GROUP BY o.OrganizationName, c.CurrencyAlternateKey
ORDER BY org_currency, o.OrganizationName;
GO
-- Results (02 Nov 2026):
--   A. Every finance row has a monthly rate (0 rows without rate for AUD,
--      CAD, EUR; USD also has rate rows, but USD is always converted at 1.0).
--   B. After conversion, salaries per head: Australia 4,303, Canada 4,905,
--      France 3,145, Germany 2,411. All four now inside the USD range
--      (2,320-5,011); before, Australia and Canada were far above it.
--      Rent per square foot: Canada 0.055 and France 0.054 inside the USD
--      range; Australia fell from 0.224 to 0.118 but stays above it;
--      Germany 0.017 was below the range before and after (rate near 1).
-- Decision: finance amounts are in LOCAL currency. Convert to USD with
-- the database's rates, looked up on the ORIGINAL (DW timeline) date.
-- Keep amount_local, currency_code, exchange_rate and amount_usd.