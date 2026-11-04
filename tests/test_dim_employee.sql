/*
  test_dim_employee.sql
  Tests for sql/02_warehouse/15_dim_department.sql, 16_dim_shift.sql,
  17_dim_employee.sql, 18_dim_employee_hr.sql (and the hr_as_of_date
  setting in 05_etl_settings.sql). Needs staging loaded.
  Expected results are written above each check.
*/

USE EnterpriseBI_DW;
GO

-- 0. Load the four dimensions in one real batch (employee before employee HR).
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_department  @batch_id = @batch_id;
EXEC etl.load_dim_shift       @batch_id = @batch_id;
EXEC etl.load_dim_employee    @batch_id = @batch_id;
EXEC etl.load_dim_employee_hr @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
GO

-- 1. Row counts. Expected: department 17, shift 4, employee 292 (290 + 2),
--    employee HR 291 (290 + 1). All PASS.
WITH c (dimension, expected_rows, actual_rows) AS (
    SELECT 'dw.dim_department',  17,  (SELECT COUNT(*) FROM dw.dim_department)  UNION ALL
    SELECT 'dw.dim_shift',        4,  (SELECT COUNT(*) FROM dw.dim_shift)       UNION ALL
    SELECT 'dw.dim_employee',   292,  (SELECT COUNT(*) FROM dw.dim_employee)    UNION ALL
    SELECT 'dw.dim_employee_hr', 291, (SELECT COUNT(*) FROM dw.dim_employee_hr)
)
SELECT dimension, expected_rows, actual_rows,
       CASE WHEN expected_rows = actual_rows THEN 'PASS' ELSE 'FAIL' END AS result
FROM c;
GO

-- 2. Rules. Expected: every row PASS.
WITH r (rule_checked, expected_value, actual_value) AS (
    SELECT 'Employees missing in employee HR', '0',
           CAST((SELECT COUNT(*) FROM dw.dim_employee e WHERE e.row_type = 'Source'
                  AND NOT EXISTS (SELECT 1 FROM dw.dim_employee_hr h WHERE h.employee_key = e.employee_key)) AS varchar(20))
    UNION ALL
    SELECT 'Employee HR rows without an employee', '0',
           CAST((SELECT COUNT(*) FROM dw.dim_employee_hr h
                 WHERE NOT EXISTS (SELECT 1 FROM dw.dim_employee e WHERE e.employee_key = h.employee_key)) AS varchar(20))
    UNION ALL
    SELECT 'Employees with a real manager', '289',
           CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE row_type = 'Source' AND manager_key > 0) AS varchar(20))
    UNION ALL
    SELECT 'Manager of the Chief Executive Officer', '-2',
           CAST((SELECT manager_key FROM dw.dim_employee WHERE job_title = N'Chief Executive Officer') AS varchar(20))
    UNION ALL
    SELECT 'Level-1 employees reporting to the CEO', '6',
           CAST((SELECT COUNT(*) FROM dw.dim_employee e
                 JOIN dw.dim_employee m ON m.employee_key = e.manager_key
                 WHERE e.organization_level = 1 AND m.job_title = N'Chief Executive Officer') AS varchar(20))
    UNION ALL
    SELECT 'Employees who manage themselves', '0',
           CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE manager_key = employee_key) AS varchar(20))
    UNION ALL
    SELECT 'Employees with unknown manager (-1)', '0',
           CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE row_type = 'Source' AND manager_key = -1) AS varchar(20))
    UNION ALL
    SELECT 'Salespeople', '17',
           CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE is_salesperson = 1) AS varchar(20))
    UNION ALL
    SELECT 'Buyers', '12',
           CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE is_buyer = 1) AS varchar(20))
    UNION ALL
    SELECT 'Employees without a current department', '0',
           CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE row_type = 'Source' AND current_department = N'Unknown') AS varchar(20))
    UNION ALL
    SELECT 'Employees in Production', '179',
           CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE current_department = N'Production') AS varchar(20))
    UNION ALL
    SELECT 'Employees in Executive', '2',
           CAST((SELECT COUNT(*) FROM dw.dim_employee WHERE current_department = N'Executive') AS varchar(20))
    UNION ALL
    SELECT 'Women', '84',
           CAST((SELECT COUNT(*) FROM dw.dim_employee_hr WHERE gender = 'Female') AS varchar(20))
    UNION ALL
    SELECT 'Men', '206',
           CAST((SELECT COUNT(*) FROM dw.dim_employee_hr WHERE gender = 'Male') AS varchar(20))
    UNION ALL
    SELECT 'Salaried employees', '52',
           CAST((SELECT COUNT(*) FROM dw.dim_employee_hr WHERE pay_type = 'Salaried') AS varchar(20))
    UNION ALL
    SELECT 'Employees with unknown age band', '0',
           CAST((SELECT COUNT(*) FROM dw.dim_employee_hr WHERE row_type = 'Source' AND age_band = 'Unknown') AS varchar(20))
    UNION ALL
    SELECT 'First hire date (shifted)', '2017-06-29',
           CONVERT(varchar(20), (SELECT MIN(hire_date) FROM dw.dim_employee_hr), 23)
    UNION ALL
    SELECT 'Last hire date (shifted)', '2024-05-29',
           CONVERT(varchar(20), (SELECT MAX(hire_date) FROM dw.dim_employee_hr), 23)
    UNION ALL
    SELECT 'Birth date columns in employee HR', '0',
           CAST((SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                 WHERE TABLE_SCHEMA = 'dw' AND TABLE_NAME = 'dim_employee_hr' AND COLUMN_NAME LIKE '%birth%') AS varchar(20))
    UNION ALL
    SELECT 'Special row -2 name', 'No salesperson',
           (SELECT employee_name FROM dw.dim_employee WHERE employee_key = -2)
)
SELECT rule_checked, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 3. Age bands on 2025-10-31 (information, no fixed expectation: ages are
--    now exact to the birthday, so they differ slightly from the earlier
--    year-only check on 2025-06-30). Expected: totals 290.
SELECT age_band, COUNT(*) AS employees
FROM dw.dim_employee_hr
WHERE row_type = 'Source'
GROUP BY age_band
ORDER BY age_band;
GO

-- 4. Lineage. Expected: 0 in all four.
SELECT 'dw.dim_department' AS dimension, COUNT(*) AS rows_without_lineage FROM dw.dim_department  WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL UNION ALL
SELECT 'dw.dim_shift',                   COUNT(*)                         FROM dw.dim_shift       WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL UNION ALL
SELECT 'dw.dim_employee',                COUNT(*)                         FROM dw.dim_employee    WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL UNION ALL
SELECT 'dw.dim_employee_hr',             COUNT(*)                         FROM dw.dim_employee_hr WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL;
GO

-- 5. Re-run: a second load of all four writes nothing.
--    Expected: 4 steps, all Succeeded, total rows_written = 0.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_department  @batch_id = @batch_id;
EXEC etl.load_dim_shift       @batch_id = @batch_id;
EXEC etl.load_dim_employee    @batch_id = @batch_id;
EXEC etl.load_dim_employee_hr @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  COUNT(*)                                              AS steps,
        SUM(CASE WHEN status = 'Succeeded' THEN 1 ELSE 0 END) AS steps_succeeded,
        SUM(rows_written)                                     AS total_rows_written
FROM etl.load_log
WHERE batch_id = @batch_id;
GO
