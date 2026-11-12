/*
  test_pipeline.sql
  Tests for sql/02_warehouse/30_security_user_region.sql, 31_pipeline.sql and 32_agent_job.sql.
  Runs the whole pipeline once (it reloads staging itself), checks the log, the data quality
  results and the facts, then proves the two failure paths of Option A (D118): a failed Error
  check and a failing step both roll back everything and keep the evidence. Also proves the
  staging count stop (D100), the security table and the Agent job definition.
  Expected results are written above each check.
*/

USE EnterpriseBI_DW;
GO

-- 1. Definitions. Expected: 1 row: 27 checks, 9 Error, 18 Warning, 4 users, 1 Executive, 3 Regional Manager.
SELECT  (SELECT COUNT(*) FROM etl.dq_check WHERE is_active = 1)                 AS checks,
        (SELECT COUNT(*) FROM etl.dq_check WHERE severity = 'Error')            AS error_checks,
        (SELECT COUNT(*) FROM etl.dq_check WHERE severity = 'Warning')          AS warning_checks,
        (SELECT COUNT(*) FROM dw.security_user_region)                          AS users,
        (SELECT COUNT(*) FROM dw.security_user_region WHERE security_role = 'Executive')        AS executives,
        (SELECT COUNT(*) FROM dw.security_user_region WHERE security_role = 'Regional Manager') AS regional_managers;
GO

-- 2. A full run succeeds. Expected: 1 row: Succeeded, 62 steps (36 staging, 1 staging check,
--    17 dimensions, 7 facts, 1 quality check), 62 succeeded, 27 check results, 0 Fail, 0 Warn,
--    0 open transactions. Run seconds are information.
DECLARE @batch_id int, @run_error nvarchar(2048);
BEGIN TRY
    EXEC etl.run_pipeline @batch_id = @batch_id OUTPUT;
END TRY
BEGIN CATCH
    SET @run_error = ERROR_MESSAGE();
END CATCH;

SELECT  b.batch_id, b.status, @run_error AS run_error,
        (SELECT COUNT(*) FROM etl.load_log l WHERE l.batch_id = b.batch_id)                          AS steps,
        (SELECT COUNT(*) FROM etl.load_log l WHERE l.batch_id = b.batch_id AND l.status = 'Succeeded') AS steps_succeeded,
        (SELECT COUNT(*) FROM etl.dq_result r WHERE r.batch_id = b.batch_id)                         AS check_results,
        (SELECT COUNT(*) FROM etl.dq_result r WHERE r.batch_id = b.batch_id AND r.status = 'Fail')   AS failed,
        (SELECT COUNT(*) FROM etl.dq_result r WHERE r.batch_id = b.batch_id AND r.status = 'Warn')   AS warned,
        @@TRANCOUNT                                                                                  AS open_transactions,
        DATEDIFF(second, b.started_at, b.ended_at)                                                   AS run_seconds
FROM etl.load_batch b
WHERE b.batch_id = @batch_id;
GO

-- 3. Every check result of that run. Expected: 27 rows, every status Pass. Measured values that
--    the design checks fixed: E01-E09 0; W01-W04 0; W05 64; W06 2151; W07 7; W08 at most 534
--    (its exact value is measured here for the first time); W09, W10 0; W11 342; W12 about 21.4;
--    W13 about 93.5; W14-W18 0.
SELECT  r.check_name, r.severity, r.measured_value, r.expected_value, r.status, r.details
FROM etl.dq_result r
WHERE r.batch_id = (SELECT MAX(batch_id) FROM etl.load_batch WHERE status = 'Succeeded')
ORDER BY r.check_name;
GO

-- 4. Every fact comes from that run. Expected: 7 rows with the tested row counts
--    (121317, 163, 72591, 8845, 1123, 12333, 39409) and rows_from_other_batches 0.
DECLARE @good int = (SELECT MAX(batch_id) FROM etl.load_batch WHERE status = 'Succeeded');
SELECT 'fact_sales' AS fact, COUNT(*) AS rows_, SUM(CASE WHEN batch_id <> @good THEN 1 ELSE 0 END) AS rows_from_other_batches FROM dw.fact_sales
UNION ALL SELECT 'fact_sales_quota', COUNT(*), SUM(CASE WHEN batch_id <> @good THEN 1 ELSE 0 END) FROM dw.fact_sales_quota
UNION ALL SELECT 'fact_work_order', COUNT(*), SUM(CASE WHEN batch_id <> @good THEN 1 ELSE 0 END) FROM dw.fact_work_order
UNION ALL SELECT 'fact_purchase', COUNT(*), SUM(CASE WHEN batch_id <> @good THEN 1 ELSE 0 END) FROM dw.fact_purchase
UNION ALL SELECT 'fact_inventory_current', COUNT(*), SUM(CASE WHEN batch_id <> @good THEN 1 ELSE 0 END) FROM dw.fact_inventory_current
UNION ALL SELECT 'fact_headcount_monthly', COUNT(*), SUM(CASE WHEN batch_id <> @good THEN 1 ELSE 0 END) FROM dw.fact_headcount_monthly
UNION ALL SELECT 'fact_finance', COUNT(*), SUM(CASE WHEN batch_id <> @good THEN 1 ELSE 0 END) FROM dw.fact_finance;
GO

-- 5. Failure path 1: an Error check fails (E07 made impossible for one run, then restored).
--    Expected: 1 row: run_result failed, batch Failed, E07 Fail, 27 check results kept,
--    63 log rows kept (62 steps + 'pipeline: rolled back'), facts and staging still from the last
--    good run (0 rows from the failed batch), E07 restored to 0, 0 open transactions.
DECLARE @good int = (SELECT MAX(batch_id) FROM etl.load_batch WHERE status = 'Succeeded');
DECLARE @batch_id int, @run_result varchar(20);

UPDATE etl.dq_check SET expected_value = -1 WHERE check_code = 'E07';
BEGIN TRY
    EXEC etl.run_pipeline @batch_id = @batch_id OUTPUT;
    SET @run_result = 'NOT failed';
END TRY
BEGIN CATCH
    SET @run_result = CASE WHEN ERROR_NUMBER() = 50005 THEN 'failed' ELSE 'other error' END;
END CATCH;
UPDATE etl.dq_check SET expected_value = 0 WHERE check_code = 'E07';

SET @batch_id = (SELECT MAX(batch_id) FROM etl.load_batch);
SELECT  @run_result                                                                       AS run_result,
        (SELECT status FROM etl.load_batch WHERE batch_id = @batch_id)                    AS batch_status,
        (SELECT status FROM etl.dq_result WHERE batch_id = @batch_id AND check_name LIKE 'E07%') AS e07_status,
        (SELECT COUNT(*) FROM etl.dq_result WHERE batch_id = @batch_id)                   AS check_results_kept,
        (SELECT COUNT(*) FROM etl.load_log WHERE batch_id = @batch_id)                    AS log_rows_kept,
        (SELECT COUNT(*) FROM dw.fact_sales WHERE batch_id = @batch_id)
      + (SELECT COUNT(*) FROM dw.fact_finance WHERE batch_id = @batch_id)
      + (SELECT COUNT(*) FROM stg.aw_sales_order_detail WHERE batch_id = @batch_id)       AS rows_from_failed_batch,
        (SELECT COUNT(*) FROM dw.fact_sales WHERE batch_id = @good)                       AS sales_rows_from_good_batch,
        (SELECT expected_value FROM etl.dq_check WHERE check_code = 'E07')                AS e07_expected_now,
        @@TRANCOUNT                                                                       AS open_transactions;
GO

-- 6. Failure path 2: a step fails (a territory map row pointing nowhere makes dim_organization
--    stop, D98), then the bad row is removed.
--    Expected: 1 row: run_result failed, batch Failed, dim_organization step Failed with its
--    message kept, 1 check result kept (E01, run before the dimensions), 0 rows from the failed
--    batch, map back to 9 rows, 0 open transactions.
DECLARE @batch_id int, @run_result varchar(20);

INSERT INTO etl.org_territory_map (organization_id, organization_name, territory_code)
VALUES (99, N'Test map row', 'NO-SUCH-TERRITORY');
BEGIN TRY
    EXEC etl.run_pipeline @batch_id = @batch_id OUTPUT;
    SET @run_result = 'NOT failed';
END TRY
BEGIN CATCH
    SET @run_result = CASE WHEN ERROR_NUMBER() = 50005 THEN 'failed' ELSE 'other error' END;
END CATCH;
DELETE FROM etl.org_territory_map WHERE organization_id = 99 AND territory_code = 'NO-SUCH-TERRITORY';

SET @batch_id = (SELECT MAX(batch_id) FROM etl.load_batch);
SELECT  @run_result                                                                         AS run_result,
        (SELECT status FROM etl.load_batch WHERE batch_id = @batch_id)                      AS batch_status,
        (SELECT status FROM etl.load_log WHERE batch_id = @batch_id AND step_name = 'dw.dim_organization') AS dim_organization_step,
        (SELECT LEFT(error_message, 120) FROM etl.load_log WHERE batch_id = @batch_id AND step_name = 'dw.dim_organization') AS kept_message,
        (SELECT COUNT(*) FROM etl.dq_result WHERE batch_id = @batch_id)                     AS check_results_kept,
        (SELECT COUNT(*) FROM dw.fact_sales WHERE batch_id = @batch_id)
      + (SELECT COUNT(*) FROM stg.aw_sales_order_detail WHERE batch_id = @batch_id)
      + (SELECT COUNT(*) FROM dw.dim_organization WHERE updated_batch_id = @batch_id)       AS rows_from_failed_batch,
        (SELECT COUNT(*) FROM etl.org_territory_map)                                        AS map_rows_now,
        @@TRANCOUNT                                                                         AS open_transactions;
GO

-- 7. The staging count check stops the run (D100), inside a transaction that is rolled back:
--    one staging shift row is removed, then the check runs on its own.
--    Expected: 1 row: check_result stopped, measured 1, details naming stg.aw_shift,
--    0 open transactions, staging shifts back to 3 after the rollback.
DECLARE @batch_id int, @check_result varchar(20), @measured decimal(18,4), @details nvarchar(4000);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRANSACTION;
DELETE TOP (1) FROM stg.aw_shift;
BEGIN TRY
    EXEC etl.check_staging_counts @batch_id = @batch_id;
    SET @check_result = 'NOT stopped';
END TRY
BEGIN CATCH
    SET @check_result = CASE WHEN ERROR_NUMBER() = 50003 THEN 'stopped' ELSE 'other error' END;
END CATCH;
SELECT @measured = measured_value, @details = details FROM etl.dq_result WHERE batch_id = @batch_id AND check_name LIKE 'E01%';
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';

SELECT  @check_result AS check_result, @measured AS measured, @details AS details,
        @@TRANCOUNT AS open_transactions,
        (SELECT COUNT(*) FROM stg.aw_shift) AS staging_shifts_now;
GO

-- 8. Security table (D71-D73, D117). Expected: 3 rows, all PASS.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Regional managers and their regions', '274 North America; 285 Pacific; 287 Europe',
           (SELECT STRING_AGG(CONCAT(employee_id, ' ', region_group), '; ') WITHIN GROUP (ORDER BY employee_id)
            FROM dw.security_user_region WHERE security_role = 'Regional Manager')
    UNION ALL
    SELECT 'Users whose employee is not in dim_employee', '0',
           CAST((SELECT COUNT(*) FROM dw.security_user_region s
                 WHERE NOT EXISTS (SELECT 1 FROM dw.dim_employee e WHERE e.employee_id = s.employee_id)) AS varchar(100))
    UNION ALL
    SELECT 'Manager region equals the region of all their orders (quota check C)', '0',
           CAST((SELECT COUNT(*) FROM dw.security_user_region s
                 WHERE s.security_role = 'Regional Manager'
                   AND EXISTS (SELECT 1 FROM dw.fact_sales f
                               JOIN dw.dim_employee e  ON e.employee_key = f.salesperson_key
                               JOIN dw.dim_territory t ON t.territory_key = f.territory_key
                               WHERE e.employee_id = s.employee_id AND t.region_group <> s.region_group)) AS varchar(100))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 9. Agent job definition (D78). Expected: 1 row: enabled 1, 1 step running
--    'EXEC etl.run_pipeline;' in EnterpriseBI_DW, daily (freq_type 4) at 20000 (02:00:00).
SELECT  j.name, j.enabled,
        (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps s WHERE s.job_id = j.job_id) AS steps,
        st.command, st.database_name, sc.freq_type, sc.freq_interval, sc.active_start_time
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps st       ON st.job_id = j.job_id
JOIN msdb.dbo.sysjobschedules js   ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules sc      ON sc.schedule_id = js.schedule_id
WHERE j.name = N'EnterpriseBI_DW nightly load';
GO
