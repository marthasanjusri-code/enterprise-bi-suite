/*
  fact_headcount_monthly_checks.sql
  Design checks for dw.fact_headcount_monthly (one row per employee per
  month-end): department history, pay history, hire dates, and headcount
  at sample month-ends after the HR date shift.

  Source: AdventureWorks2025. Read-only.
  HR dates are shifted +4,017 days to the OLTP sales timeline.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- fact_headcount_monthly: one row per employee per month-end (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. Department history: every employee should have exactly one open
--    period (EndDate NULL) and no overlapping periods.
WITH open_rows AS (
    SELECT  e.BusinessEntityID,
            SUM(CASE WHEN h.EndDate IS NULL THEN 1 ELSE 0 END) AS open_periods,
            COUNT(h.BusinessEntityID)                          AS periods
    FROM HumanResources.Employee e
    LEFT JOIN HumanResources.EmployeeDepartmentHistory h
           ON h.BusinessEntityID = e.BusinessEntityID
    GROUP BY e.BusinessEntityID
)
SELECT  COUNT(*)                                           AS employees,
        SUM(CASE WHEN periods = 0      THEN 1 ELSE 0 END)  AS without_department,
        SUM(CASE WHEN open_periods = 0 THEN 1 ELSE 0 END)  AS no_open_period,
        SUM(CASE WHEN open_periods > 1 THEN 1 ELSE 0 END)  AS several_open_periods,
        SUM(CASE WHEN periods > 1      THEN 1 ELSE 0 END)  AS changed_department
FROM open_rows;

SELECT  COUNT(*) AS overlapping_period_pairs
FROM HumanResources.EmployeeDepartmentHistory a
JOIN HumanResources.EmployeeDepartmentHistory b
  ON b.BusinessEntityID = a.BusinessEntityID
 AND b.StartDate > a.StartDate
 AND b.StartDate <= ISNULL(a.EndDate, '9999-12-31');

-- 2. How do department periods connect (same day, next day, gap)?
--    And does the first department start on the hire date?
SELECT  DATEDIFF(day, a.EndDate, b.StartDate) AS days_between_periods,
        COUNT(*)                              AS period_pairs
FROM HumanResources.EmployeeDepartmentHistory a
JOIN HumanResources.EmployeeDepartmentHistory b
  ON b.BusinessEntityID = a.BusinessEntityID
 AND b.StartDate = (SELECT MIN(x.StartDate)
                    FROM HumanResources.EmployeeDepartmentHistory x
                    WHERE x.BusinessEntityID = a.BusinessEntityID
                      AND x.StartDate > a.StartDate)
GROUP BY DATEDIFF(day, a.EndDate, b.StartDate);

WITH first_dept AS (
    SELECT BusinessEntityID, MIN(StartDate) AS first_start
    FROM HumanResources.EmployeeDepartmentHistory
    GROUP BY BusinessEntityID
)
SELECT  SUM(CASE WHEN f.first_start = e.HireDate THEN 1 ELSE 0 END) AS starts_on_hire_date,
        SUM(CASE WHEN f.first_start > e.HireDate THEN 1 ELSE 0 END) AS starts_after_hire,
        SUM(CASE WHEN f.first_start < e.HireDate THEN 1 ELSE 0 END) AS starts_before_hire,
        MAX(DATEDIFF(day, e.HireDate, f.first_start))               AS max_days_after_hire
FROM HumanResources.Employee e
JOIN first_dept f ON f.BusinessEntityID = e.BusinessEntityID;

-- 3. Pay history: does every employee have a rate, and does the first
--    rate start on the hire date? How often do rates change?
WITH pay AS (
    SELECT  BusinessEntityID,
            COUNT(*)            AS rate_rows,
            MIN(RateChangeDate) AS first_rate_date
    FROM HumanResources.EmployeePayHistory
    GROUP BY BusinessEntityID
)
SELECT  COUNT(*)                                                            AS employees,
        SUM(CASE WHEN p.BusinessEntityID IS NULL THEN 1 ELSE 0 END)         AS without_pay_rate,
        SUM(CASE WHEN p.rate_rows > 1 THEN 1 ELSE 0 END)                    AS with_rate_changes,
        SUM(CASE WHEN CAST(p.first_rate_date AS date) = e.HireDate THEN 1 ELSE 0 END) AS first_rate_on_hire_date,
        SUM(CASE WHEN CAST(p.first_rate_date AS date) > e.HireDate THEN 1 ELSE 0 END) AS first_rate_after_hire,
        SUM(CASE WHEN CAST(p.first_rate_date AS date) < e.HireDate THEN 1 ELSE 0 END) AS first_rate_before_hire
FROM HumanResources.Employee e
LEFT JOIN pay p ON p.BusinessEntityID = e.BusinessEntityID;

-- 4. Meaning of the pay and leave columns, and how pay frequency relates
--    to the salaried flag.
SELECT  OBJECT_NAME(ep.major_id)        AS table_name,
        c.name                          AS column_name,
        CAST(ep.value AS nvarchar(500)) AS description
FROM sys.extended_properties ep
JOIN sys.columns c ON c.object_id = ep.major_id AND c.column_id = ep.minor_id
WHERE ep.name = 'MS_Description' AND ep.class = 1
  AND (   (ep.major_id = OBJECT_ID('HumanResources.EmployeePayHistory')
           AND c.name IN ('Rate', 'PayFrequency'))
       OR (ep.major_id = OBJECT_ID('HumanResources.Employee')
           AND c.name IN ('SalariedFlag', 'VacationHours', 'SickLeaveHours')))
ORDER BY table_name, column_name;

WITH latest_pay AS (
    SELECT  BusinessEntityID, PayFrequency, Rate,
            ROW_NUMBER() OVER (PARTITION BY BusinessEntityID ORDER BY RateChangeDate DESC) AS rn
    FROM HumanResources.EmployeePayHistory
)
SELECT  e.SalariedFlag,
        p.PayFrequency,
        COUNT(*)    AS employees,
        MIN(p.Rate) AS min_rate,
        MAX(p.Rate) AS max_rate
FROM HumanResources.Employee e
JOIN latest_pay p ON p.BusinessEntityID = e.BusinessEntityID AND p.rn = 1
GROUP BY e.SalariedFlag, p.PayFrequency
ORDER BY e.SalariedFlag, p.PayFrequency;

-- 5. Headcount at sample month-ends after the +4,017 day shift, and how
--    many of those employees have no department covering that date.
WITH months AS (
    SELECT CAST('2022-05-31' AS date) AS month_end UNION ALL
    SELECT CAST('2023-12-31' AS date) UNION ALL
    SELECT CAST('2024-12-31' AS date) UNION ALL
    SELECT CAST('2025-06-30' AS date)
),
emp AS (
    SELECT BusinessEntityID, DATEADD(day, 4017, HireDate) AS hire_date
    FROM HumanResources.Employee
),
dept AS (
    SELECT  BusinessEntityID,
            DATEADD(day, 4017, StartDate) AS start_date,
            CASE WHEN EndDate IS NULL THEN CAST('9999-12-31' AS date)
                 ELSE DATEADD(day, 4017, EndDate) END AS end_date
    FROM HumanResources.EmployeeDepartmentHistory
),
emp_month AS (
    SELECT  m.month_end,
            e.BusinessEntityID,
            CASE WHEN EXISTS (SELECT 1 FROM dept d
                              WHERE d.BusinessEntityID = e.BusinessEntityID
                                AND m.month_end >= d.start_date
                                AND m.month_end <= d.end_date)
                 THEN 1 ELSE 0 END AS has_department
    FROM months m
    JOIN emp e ON e.hire_date <= m.month_end
)
SELECT  month_end,
        COUNT(*)                AS employed,
        SUM(1 - has_department) AS employed_without_department
FROM emp_month
GROUP BY month_end
ORDER BY month_end;
GO
-- Results (03 Nov 2026):
--   1. 290 employees: none without a department, each with exactly one
--      open period, 0 overlapping periods. 5 employees changed department.
--   2. All 6 period pairs: next period starts 1 day after the previous
--      EndDate (EndDate inclusive). First department starts on the hire
--      date for all 290.
--   3. Every employee has a pay rate; 13 had rate changes. First rate on
--      the hire date for 288; for 2 it is BEFORE the hire date (source
--      anomaly; harmless for an "as of month-end" lookup).
--   4. Rate = "Salary hourly rate" for everyone, so average rate is
--      comparable across employees. PayFrequency = how often pay is
--      received (1 monthly, 2 biweekly). SalariedFlag 0 = hourly,
--      1 = salaried. Vacation and sick leave = hours available NOW.
--      Hourly + monthly 164 (9.00-15.00), hourly + biweekly 74
--      (9.50-32.45), salaried + biweekly 52 (19.23-125.50).
--   5. After the +4,017 day shift: 283 employed at 2022-05-31, 287 at
--      2023-12-31, 290 at 2024-12-31 and 2025-06-30. Nobody without a
--      department on any sample date.
-- Decisions:
--   - Department, shift and pay rate are looked up "as of" each month-end.
--   - Leave hours and salaried flag stay in dim_employee (current only).
--   - Headcount is semi-additive: closing or average, never summed over
--     months. Revenue per employee uses average headcount of the period.
--   - Average pay is hidden for any group with fewer than 5 employees, so
--     no individual's pay can be read from the report.
--   - Hires per year uses hire dates in dim_employee (2017-2024 after the
--     shift); the snapshot covers the report window set in dim_date.