/*
  test_fact_finance.sql
  Tests for sql/02_warehouse/29_fact_finance.sql. Needs staging loaded.
  Loads the calendar, the four finance dimensions (and dim_territory, which dim_organization
  needs) and the fact in one real batch, checks it against staging, the finance checks and the
  queries of 10 Nov 2026, proves that an empty staging is refused, and re-runs it.
  Fixed numbers come from sql/01_design_checks/fact_finance_checks.sql and dim_finance_checks.sql;
  the rest are compared with staging, never with the load itself.
*/

USE EnterpriseBI_DW;
GO

-- Precondition: staging must be loaded, or every check below is meaningless.
-- NOEXEC ON skips every later batch; it is switched off again at the end of the script.
IF NOT EXISTS (SELECT 1 FROM stg.awdw_fact_finance)
   OR NOT EXISTS (SELECT 1 FROM stg.awdw_fact_currency_rate)
   OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_organization)
   OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_currency)
   OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_account)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_sales_territory)
BEGIN
    RAISERROR('Staging is empty. Run etl.load_staging first; tests stopped.', 16, 1);
    SET NOEXEC ON;
END;
GO

-- 0. Load the calendar, the dimensions and the fact in one real batch.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_date @batch_id = @batch_id;
EXEC etl.load_dim_territory @batch_id = @batch_id;
EXEC etl.load_dim_scenario @batch_id = @batch_id;
EXEC etl.load_dim_finance_department_group @batch_id = @batch_id;
EXEC etl.load_dim_organization @batch_id = @batch_id;
EXEC etl.load_dim_account @batch_id = @batch_id;
EXEC etl.load_fact_finance @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
SELECT @batch_id AS test_batch_id;
GO

-- 1. Grain, dates, keys and amounts. Expected: 18 rows, all PASS.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Rows = staging rows',
           CAST((SELECT COUNT(*) FROM stg.awdw_fact_finance) AS varchar(200)),
           CAST((SELECT COUNT(*) FROM dw.fact_finance) AS varchar(200))
    UNION ALL
    SELECT 'Rows (finance check 1)', '39409',
           CAST((SELECT COUNT(*) FROM dw.fact_finance) AS varchar(200))
    UNION ALL
    SELECT 'Periods: count / first / last (D33)', '37 / 2022-05-31 / 2025-05-31',
           (SELECT CONCAT(COUNT(DISTINCT f.period_date_key), ' / ', CONVERT(char(10), MIN(d.full_date), 23), ' / ', CONVERT(char(10), MAX(d.full_date), 23))
            FROM dw.fact_finance f JOIN dw.dim_date d ON d.date_key = f.period_date_key)
    UNION ALL
    SELECT 'Periods whose date is not a month-end', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f JOIN dw.dim_date d ON d.date_key = f.period_date_key
                 WHERE d.is_month_end = 0) AS varchar(200))
    UNION ALL
    SELECT 'Adjustment rows: count / source dates / periods (D34, query of 10 Nov 2026)',
           '46 / 2011-12-28, 2012-12-27 / 2023-05-31, 2024-05-31',
           (SELECT CONCAT(COUNT(*), ' / ',
                          (SELECT STRING_AGG(CONVERT(char(10), x.source_date, 23), ', ') WITHIN GROUP (ORDER BY x.source_date)
                           FROM (SELECT DISTINCT source_date FROM dw.fact_finance WHERE entry_type = 'Year-end adjustment') x), ' / ',
                          (SELECT STRING_AGG(CONVERT(char(10), x.full_date, 23), ', ') WITHIN GROUP (ORDER BY x.full_date)
                           FROM (SELECT DISTINCT d.full_date FROM dw.fact_finance f JOIN dw.dim_date d ON d.date_key = f.period_date_key
                                 WHERE f.entry_type = 'Year-end adjustment') x))
            FROM dw.fact_finance WHERE entry_type = 'Year-end adjustment')
    UNION ALL
    SELECT 'Months where a regular and an adjustment row share the grain (finance check 2d)', '6',
           CAST((SELECT COUNT(*) FROM (
                    SELECT period_date_key, organization_key, finance_department_group_key, account_key, scenario_key
                    FROM dw.fact_finance
                    GROUP BY period_date_key, organization_key, finance_department_group_key, account_key, scenario_key
                    HAVING COUNT(*) > 1) x) AS varchar(200))
    UNION ALL
    SELECT 'Source dates that differ from staging', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f
                 JOIN stg.awdw_fact_finance s ON s.FinanceKey = f.finance_id
                 WHERE f.source_date <> CAST(s.[Date] AS date)) AS varchar(200))
    UNION ALL
    SELECT 'Unknown organisation / department group / account / scenario (-1)', '0 / 0 / 0 / 0',
           (SELECT CONCAT(SUM(CASE WHEN organization_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN finance_department_group_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN account_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN scenario_key = -1 THEN 1 ELSE 0 END)) FROM dw.fact_finance)
    UNION ALL
    SELECT 'Rows on parent accounts / parent units (checks 3 and 4: leaves only)', '0 / 0',
           (SELECT CONCAT(SUM(CASE WHEN a.is_leaf = 0 THEN 1 ELSE 0 END), ' / ', SUM(CASE WHEN o.is_leaf = 0 THEN 1 ELSE 0 END))
            FROM dw.fact_finance f
            JOIN dw.dim_account a      ON a.account_key = f.account_key
            JOIN dw.dim_organization o ON o.organization_key = f.organization_key)
    UNION ALL
    SELECT 'Rows on Corporate (direct) (check 4, D35)', '8843',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f
                 JOIN dw.dim_finance_department_group g ON g.finance_department_group_key = f.finance_department_group_key
                 WHERE g.is_corporate_direct = 1) AS varchar(200))
    UNION ALL
    SELECT 'Organisations whose row count differs from staging', '0',
           CAST((SELECT COUNT(*) FROM (
                    SELECT o.organization_id, COUNT(*) AS n FROM dw.fact_finance f
                    JOIN dw.dim_organization o ON o.organization_key = f.organization_key GROUP BY o.organization_id) a
                 FULL JOIN (SELECT OrganizationKey, COUNT(*) AS n FROM stg.awdw_fact_finance GROUP BY OrganizationKey) b
                   ON b.OrganizationKey = a.organization_id
                 WHERE a.n IS NULL OR b.n IS NULL OR a.n <> b.n) AS varchar(200))
    UNION ALL
    SELECT 'Sum of amount_local = staging (2 decimals)',
           CAST((SELECT SUM(CAST(ROUND(Amount, 2) AS decimal(19,2))) FROM stg.awdw_fact_finance) AS varchar(200)),
           CAST((SELECT SUM(amount_local) FROM dw.fact_finance) AS varchar(200))
    UNION ALL
    SELECT 'Rows whose amount_local differs from the source amount', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f
                 JOIN stg.awdw_fact_finance s ON s.FinanceKey = f.finance_id
                 WHERE CAST(f.amount_local AS float) <> s.Amount) AS varchar(200))
    UNION ALL
    SELECT 'Rows whose currency differs from the unit currency in dim_organization', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f
                 JOIN dw.dim_organization o ON o.organization_key = f.organization_key
                 WHERE f.currency_code <> o.currency_code) AS varchar(200))
    UNION ALL
    SELECT 'Balance sheet rows by currency (query of 10 Nov 2026)', 'AUD 350; CAD 1050; EUR 1402; USD 5322',
           (SELECT STRING_AGG(CONCAT(currency_code, ' ', n), '; ') WITHIN GROUP (ORDER BY currency_code)
            FROM (SELECT f.currency_code, COUNT(*) AS n FROM dw.fact_finance f
                  JOIN dw.dim_account a ON a.account_key = f.account_key
                  WHERE a.statement = 'Balance sheet' GROUP BY f.currency_code) x)
    UNION ALL
    SELECT 'May 2025 balance sheet: rows / units / units whose rows do not net to 0 (D39, query of 11 Nov 2026)', '6 / 3 / 0',
           (SELECT CONCAT(SUM(n), ' / ', COUNT(*), ' / ', SUM(CASE WHEN net <> 0 THEN 1 ELSE 0 END))
            FROM (SELECT f.organization_key, COUNT(*) AS n, SUM(f.amount_local) AS net
                  FROM dw.fact_finance f
                  JOIN dw.dim_account a ON a.account_key = f.account_key
                  WHERE a.statement = 'Balance sheet' AND f.period_date_key = 20250531
                  GROUP BY f.organization_key) x)
    UNION ALL
    SELECT 'May 2025 balance sheet rows outside accounts 3010 and 3020 (D39)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f
                 JOIN dw.dim_account a ON a.account_key = f.account_key
                 WHERE a.statement = 'Balance sheet' AND f.period_date_key = 20250531
                   AND a.account_code NOT IN ('3010', '3020')) AS varchar(200))
    UNION ALL
    SELECT 'Last period with asset rows: the closing balance month (D115)', '2025-04-30',
           (SELECT CONVERT(char(10), MAX(d.full_date), 23)
            FROM dw.fact_finance f
            JOIN dw.dim_account a ON a.account_key = f.account_key
            JOIN dw.dim_date d    ON d.date_key = f.period_date_key
            WHERE a.level_2 = N'Assets')
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 2. Currency conversion (D36). Expected: 8 rows, all PASS.
--    The rate checks recompute the rate in a different way from the load: calendar year and
--    month of the original date instead of EOMONTH, and the end-of-day rate by exact date.
--    The last row repeats dim finance check 3 (assets = liabilities + equity in every month) on
--    the loaded local amounts, Actual scenario, all entry types of a month together.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Statistical rows with a rate or a USD amount (not money)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f JOIN dw.dim_account a ON a.account_key = f.account_key
                 WHERE a.statement = 'Statistical' AND (f.exchange_rate IS NOT NULL OR f.amount_usd IS NOT NULL)) AS varchar(200))
    UNION ALL
    SELECT 'Money rows without a rate or a USD amount', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f JOIN dw.dim_account a ON a.account_key = f.account_key
                 WHERE a.statement IN ('Balance sheet', 'Income statement') AND (f.exchange_rate IS NULL OR f.amount_usd IS NULL)) AS varchar(200))
    UNION ALL
    SELECT 'USD money rows with a rate other than 1 or amount_usd <> amount_local', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f JOIN dw.dim_account a ON a.account_key = f.account_key
                 WHERE a.statement <> 'Statistical' AND f.currency_code = N'USD'
                   AND (f.exchange_rate <> 1 OR f.amount_usd <> f.amount_local)) AS varchar(200))
    UNION ALL
    SELECT 'Non-USD income statement rows whose rate differs from the monthly average', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f
                 JOIN dw.dim_account a ON a.account_key = f.account_key
                 JOIN stg.awdw_dim_currency c ON CAST(c.CurrencyAlternateKey AS nvarchar(3)) = f.currency_code
                 WHERE a.statement = 'Income statement' AND f.currency_code <> N'USD'
                   AND ABS(f.exchange_rate - (SELECT CAST(AVG(r.AverageRate) AS decimal(19,10))
                                              FROM stg.awdw_fact_currency_rate r
                                              WHERE r.CurrencyKey = c.CurrencyKey
                                                AND YEAR(r.[Date]) = YEAR(f.source_date)
                                                AND MONTH(r.[Date]) = MONTH(f.source_date))) > 0.0000000001) AS varchar(200))
    UNION ALL
    SELECT 'Non-USD balance sheet rows whose rate differs from the end-of-day rate on the source date', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance f
                 JOIN dw.dim_account a ON a.account_key = f.account_key
                 JOIN stg.awdw_dim_currency c ON CAST(c.CurrencyAlternateKey AS nvarchar(3)) = f.currency_code
                 JOIN stg.awdw_fact_currency_rate r ON r.CurrencyKey = c.CurrencyKey AND CAST(r.[Date] AS date) = f.source_date
                 WHERE a.statement = 'Balance sheet' AND f.currency_code <> N'USD'
                   AND ABS(f.exchange_rate - CAST(r.EndOfDayRate AS decimal(19,10))) > 0.0000000001) AS varchar(200))
    UNION ALL
    SELECT 'Rows where amount_usd differs from amount_local x rate by more than 0.0001', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_finance
                 WHERE exchange_rate IS NOT NULL AND ABS(amount_usd - amount_local * exchange_rate) > 0.0001) AS varchar(200))
    UNION ALL
    SELECT 'Salaries per head in USD, Actual: Australia / Canada / France / Germany (conversion test B)', '4303 / 4905 / 3145 / 2411',
           (SELECT STRING_AGG(CAST(CAST(ROUND(v, 0) AS int) AS varchar(10)), ' / ')
                   WITHIN GROUP (ORDER BY CASE organization_name WHEN N'Australia' THEN 1 WHEN N'Canadian Division' THEN 2
                                                                 WHEN N'France' THEN 3 ELSE 4 END)
            FROM (SELECT o.organization_name, AVG(m.salaries_usd / NULLIF(m.headcount, 0)) AS v
                  FROM (SELECT f.organization_key, f.source_date,
                               SUM(CASE WHEN a.account_id = 60 THEN f.amount_usd END)   AS salaries_usd,
                               SUM(CASE WHEN a.account_id = 96 THEN f.amount_local END) AS headcount
                        FROM dw.fact_finance f
                        JOIN dw.dim_account a  ON a.account_key = f.account_key
                        JOIN dw.dim_scenario s ON s.scenario_key = f.scenario_key
                        WHERE s.scenario_name = 'Actual'
                        GROUP BY f.organization_key, f.source_date) m
                  JOIN dw.dim_organization o ON o.organization_key = m.organization_key
                  WHERE o.organization_name IN (N'Australia', N'Canadian Division', N'France', N'Germany')
                  GROUP BY o.organization_name) x)
    UNION ALL
    SELECT 'Months where Assets <> Liabilities and Owners Equity, local amounts, Actual (dim finance check 3)', '0',
           CAST((SELECT COUNT(*) FROM (
                    SELECT f.period_date_key
                    FROM dw.fact_finance f
                    JOIN dw.dim_account a  ON a.account_key = f.account_key
                    JOIN dw.dim_scenario s ON s.scenario_key = f.scenario_key
                    WHERE a.statement = 'Balance sheet' AND s.scenario_name = 'Actual'
                    GROUP BY f.period_date_key
                    HAVING SUM(CASE WHEN a.level_2 = N'Assets' THEN f.amount_local ELSE 0 END)
                        <> SUM(CASE WHEN a.level_2 = N'Liabilities and Owners Equity' THEN f.amount_local ELSE 0 END)) x) AS varchar(200))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 3. Information (no pass/fail): rows and amounts by statement and currency.
SELECT  a.statement, f.currency_code, COUNT(*) AS rows_,
        CAST(SUM(f.amount_local) AS decimal(19,2)) AS amount_local,
        CAST(SUM(f.amount_usd) AS decimal(19,2))   AS amount_usd
FROM dw.fact_finance f
JOIN dw.dim_account a ON a.account_key = f.account_key
GROUP BY a.statement, f.currency_code
ORDER BY a.statement, f.currency_code;
GO

-- 4. Lineage. Expected: 1 row, rows_without_lineage = 0, batches = 1.
SELECT  SUM(CASE WHEN batch_id IS NULL OR loaded_at IS NULL THEN 1 ELSE 0 END) AS rows_without_lineage,
        COUNT(DISTINCT batch_id) AS batches
FROM dw.fact_finance;
GO

-- 5. Empty staging is refused (D106), inside a transaction that is rolled back.
--    Expected: 1 row, refused, 39409, 39409, 0.
DECLARE @batch_id int, @load_result varchar(20);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
BEGIN TRANSACTION;
DELETE FROM stg.awdw_fact_finance;
BEGIN TRY
    EXEC etl.load_fact_finance @batch_id = @batch_id;
    SET @load_result = 'NOT refused';
END TRY
BEGIN CATCH
    SET @load_result = CASE WHEN ERROR_NUMBER() = 50002 THEN 'refused' ELSE 'other error' END;
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';
SELECT  @load_result AS load_result,
        (SELECT COUNT(*) FROM dw.fact_finance)       AS fact_rows_after,
        (SELECT COUNT(*) FROM stg.awdw_fact_finance) AS staging_rows_after,
        @@TRANCOUNT                                  AS open_transactions;
GO

-- 6. Re-run gives the same result. Expected: 1 row, Succeeded, 39409, 0 rows from other batches.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_fact_finance @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  l.status, l.rows_written,
        (SELECT COUNT(*) FROM dw.fact_finance WHERE batch_id <> @batch_id) AS rows_from_other_batches,
        DATEDIFF(second, l.started_at, l.ended_at)                         AS load_seconds
FROM etl.load_log l
WHERE l.batch_id = @batch_id;
GO

-- Switch execution back on (see the precondition at the top).
SET NOEXEC OFF;
GO
