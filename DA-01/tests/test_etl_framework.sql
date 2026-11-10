/*
  test_etl_framework.sql
  Tests for sql/02_warehouse/01_create_database.sql and 02_etl_framework.sql.
  Runs inside a transaction and rolls back, so no test rows are left behind.
*/

USE EnterpriseBI_DW;
GO

-- 1. Database settings and schemas.
SELECT  DB_NAME()                                        AS database_name,
        recovery_model_desc                              AS recovery_model,
        (SELECT COUNT(*) FROM sys.schemas
          WHERE name IN ('stg', 'dw', 'etl'))            AS schemas_found
FROM sys.databases
WHERE name = DB_NAME();

-- 2. Objects exist.
SELECT  s.name + '.' + o.name AS object_name,
        o.type_desc
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = 'etl'
  AND o.type IN ('U', 'P')
ORDER BY o.type_desc, object_name;

-- 3. A full run: open batch, open and close a step, record a check,
--    close the batch. Then read it back and roll everything back.
BEGIN TRANSACTION;

DECLARE @batch_id int, @log_id int;

EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.start_step  @batch_id = @batch_id, @step_name = 'test step', @log_id = @log_id OUTPUT;
EXEC etl.end_step    @log_id = @log_id, @status = 'Succeeded', @rows_read = 10, @rows_written = 10;

INSERT INTO etl.dq_result (batch_id, check_name, severity, measured_value, expected_value, status)
VALUES (@batch_id, 'test check', 'Warning', 0, '0', 'Pass');

EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  b.batch_id, b.status AS batch_status, b.triggered_by,
        l.step_name, l.status AS step_status, l.rows_read, l.rows_written,
        CASE WHEN b.ended_at IS NOT NULL AND l.ended_at IS NOT NULL THEN 'Yes' ELSE 'No' END AS end_times_set,
        (SELECT COUNT(*) FROM etl.dq_result d WHERE d.batch_id = b.batch_id) AS dq_rows
FROM etl.load_batch b
JOIN etl.load_log l ON l.batch_id = b.batch_id
WHERE b.batch_id = @batch_id;

-- 4. Constraint test: an invalid status must be rejected.
BEGIN TRY
    EXEC etl.end_batch @batch_id = @batch_id, @status = 'Done';
    SELECT 'FAIL: invalid status accepted' AS constraint_test;
END TRY
BEGIN CATCH
    SELECT 'PASS: invalid status rejected' AS constraint_test;
END CATCH;

ROLLBACK TRANSACTION;

-- 5. Nothing left behind.
SELECT  (SELECT COUNT(*) FROM etl.load_batch) AS batches,
        (SELECT COUNT(*) FROM etl.load_log)   AS steps,
        (SELECT COUNT(*) FROM etl.dq_result)  AS dq_rows;
GO