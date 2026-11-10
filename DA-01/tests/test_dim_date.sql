/*
  test_dim_date.sql
  Tests for sql/02_warehouse/05_etl_settings.sql and 06_dim_date.sql.
  Needs staging loaded (tests/test_staging.sql or etl.load_staging).
  Runs dim_date in a real batch, checks it, then runs it again to prove
  a re-run changes nothing. Expected results are written above each check.
*/

USE EnterpriseBI_DW;
GO

-- 0. Load dim_date in a real batch.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_date @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
GO

-- 1. Settings and compatibility level.
--    Expected: 4017, 4170, 7, and compatibility level 160 or higher.
SELECT  (SELECT setting_value FROM etl.setting WHERE setting_name = 'hr_date_shift_days')      AS hr_shift,
        (SELECT setting_value FROM etl.setting WHERE setting_name = 'dw_date_shift_days')      AS dw_shift,
        (SELECT setting_value FROM etl.setting WHERE setting_name = 'fiscal_year_start_month') AS fiscal_start,
        (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME())                 AS compatibility_level;
GO

-- 2. Range and completeness. Expected: 2017-01-01 to 2025-12-31,
--    3,287 rows, 3,287 distinct dates, 0 gaps.
SELECT  MIN(full_date)                                                AS first_date,
        MAX(full_date)                                                AS last_date,
        COUNT(*)                                                      AS rows_total,
        COUNT(DISTINCT full_date)                                     AS distinct_dates,
        DATEDIFF(day, MIN(full_date), MAX(full_date)) + 1 - COUNT(*)  AS missing_days
FROM dw.dim_date;
GO

-- 3. Known dates. Expected: every row PASS.
WITH expected (full_date, check_name, expected_value) AS (
    SELECT * FROM (VALUES
        (CAST('2025-06-29' AS date), 'date_key',            '20250629'),
        (CAST('2025-06-29' AS date), 'day_name',            'Sunday'),
        (CAST('2025-06-29' AS date), 'day_of_week',         '7'),
        (CAST('2025-06-29' AS date), 'is_weekend',          '1'),
        (CAST('2024-02-29' AS date), 'month_name',          'February'),
        (CAST('2025-12-29' AS date), 'iso_week',            '1'),
        (CAST('2025-12-29' AS date), 'iso_year',            '2026'),
        (CAST('2025-12-29' AS date), 'year',                '2025'),
        (CAST('2024-07-01' AS date), 'fiscal_year_label',   'FY2025'),
        (CAST('2024-07-01' AS date), 'fiscal_month',        '1'),
        (CAST('2024-07-01' AS date), 'fiscal_quarter',      '1'),
        (CAST('2025-06-30' AS date), 'fiscal_year_quarter', 'FY2025-Q4'),
        (CAST('2025-06-30' AS date), 'fiscal_month',        '12'),
        (CAST('2025-06-30' AS date), 'is_month_end',        '1'),
        (CAST('2025-05-27' AS date), 'quota_period_label',  'Quota period 2025-02-28'),
        (CAST('2025-05-28' AS date), 'quota_period_label',  'No quota period'),
        (CAST('2022-05-29' AS date), 'quota_period_label',  'No quota period'),
        (CAST('2022-05-30' AS date), 'quota_period_label',  'Quota period 2022-05-30')
    ) v (full_date, check_name, expected_value)
),
actual AS (
    SELECT  e.full_date, e.check_name, e.expected_value,
            CASE e.check_name
                WHEN 'date_key'            THEN CAST(d.date_key AS varchar(30))
                WHEN 'day_name'            THEN d.day_name
                WHEN 'day_of_week'         THEN CAST(d.day_of_week AS varchar(30))
                WHEN 'is_weekend'          THEN CAST(d.is_weekend AS varchar(30))
                WHEN 'month_name'          THEN d.month_name
                WHEN 'iso_week'            THEN CAST(d.iso_week AS varchar(30))
                WHEN 'iso_year'            THEN CAST(d.iso_year AS varchar(30))
                WHEN 'year'                THEN CAST(d.year AS varchar(30))
                WHEN 'fiscal_year_label'   THEN d.fiscal_year_label
                WHEN 'fiscal_month'        THEN CAST(d.fiscal_month AS varchar(30))
                WHEN 'fiscal_quarter'      THEN CAST(d.fiscal_quarter AS varchar(30))
                WHEN 'fiscal_year_quarter' THEN d.fiscal_year_quarter
                WHEN 'is_month_end'        THEN CAST(d.is_month_end AS varchar(30))
                WHEN 'quota_period_label'  THEN d.quota_period_label
            END AS actual_value
    FROM expected e
    LEFT JOIN dw.dim_date d ON d.full_date = e.full_date
)
SELECT  full_date, check_name, expected_value, actual_value,
        CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM actual
ORDER BY result, full_date, check_name;
GO

-- 4. Quota periods. Expected: 12 periods, each period's end + 1 day =
--    next period's start (11 links), last period ends 2025-05-27.
WITH p AS (
    SELECT DISTINCT quota_period_start, quota_period_end
    FROM dw.dim_date
    WHERE quota_period_start IS NOT NULL
),
linked AS (
    SELECT  quota_period_start, quota_period_end,
            LEAD(quota_period_start) OVER (ORDER BY quota_period_start) AS next_start
    FROM p
)
SELECT  COUNT(*)                                                                     AS periods,
        SUM(CASE WHEN DATEADD(day, 1, quota_period_end) = next_start THEN 1 ELSE 0 END) AS linked_periods,
        MAX(quota_period_end)                                                        AS last_period_end
FROM linked;
GO

-- 5. Every date the facts will use (after the shifts) exists in dim_date.
--    Expected: missing_dates = 0.
DECLARE @hr_shift int, @dw_shift int;
EXEC etl.get_setting_int 'hr_date_shift_days', @hr_shift OUTPUT;
EXEC etl.get_setting_int 'dw_date_shift_days', @dw_shift OUTPUT;

WITH fact_dates (d) AS (
    SELECT CAST(OrderDate AS date) FROM stg.aw_sales_order_header
    UNION SELECT CAST(DueDate AS date)  FROM stg.aw_sales_order_header
    UNION SELECT CAST(ShipDate AS date) FROM stg.aw_sales_order_header
    UNION SELECT CAST(QuotaDate AS date) FROM stg.aw_sales_person_quota_history
    UNION SELECT CAST(OrderDate AS date) FROM stg.aw_purchase_order_header
    UNION SELECT CAST(ShipDate AS date)  FROM stg.aw_purchase_order_header
    UNION SELECT CAST(DueDate AS date)   FROM stg.aw_purchase_order_detail
    UNION SELECT CAST(StartDate AS date) FROM stg.aw_work_order
    UNION SELECT CAST(EndDate AS date)   FROM stg.aw_work_order
    UNION SELECT CAST(DueDate AS date)   FROM stg.aw_work_order
    UNION SELECT CAST(ModifiedDate AS date) FROM stg.aw_product_inventory
    UNION SELECT EOMONTH(DATEADD(day, @dw_shift, [Date])) FROM stg.awdw_fact_finance
    UNION SELECT DATEADD(day, @hr_shift, HireDate) FROM stg.aw_employee
)
SELECT  COUNT(*)                                                              AS distinct_fact_dates,
        SUM(CASE WHEN d.full_date IS NULL THEN 1 ELSE 0 END)                  AS missing_dates
FROM fact_dates f
LEFT JOIN dw.dim_date d ON d.full_date = f.d
WHERE f.d IS NOT NULL;
GO

-- 6. Lineage. Expected: no NULL batch ids; every row inserted by a real batch.
SELECT  SUM(CASE WHEN inserted_batch_id IS NULL OR updated_batch_id IS NULL THEN 1 ELSE 0 END) AS rows_without_lineage,
        SUM(CASE WHEN b.batch_id IS NULL THEN 1 ELSE 0 END)                                    AS rows_with_unknown_batch
FROM dw.dim_date d
LEFT JOIN etl.load_batch b ON b.batch_id = d.inserted_batch_id;
GO

-- 7. Re-run: a second load changes nothing.
--    Expected: rows_total = 3,287, rows_written by the second run = 0.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_date @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  (SELECT COUNT(*) FROM dw.dim_date)                                  AS rows_total,
        l.rows_read,
        l.rows_written,
        l.status
FROM etl.load_log l
WHERE l.batch_id = @batch_id
  AND l.step_name = 'dw.dim_date';
GO
