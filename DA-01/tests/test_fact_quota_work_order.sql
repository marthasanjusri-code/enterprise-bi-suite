/*
  test_fact_quota_work_order.sql
  Tests for sql/02_warehouse/24_fact_sales_quota.sql and 25_fact_work_order.sql.
  Needs staging loaded. Loads the calendar, the dimensions these facts use and both facts in
  one real batch, checks them against staging and the design checks, proves that an empty
  staging is refused, and re-runs to prove the result is stable.
  Fixed numbers come from sql/01_design_checks/fact_sales_quota_checks.sql and
  fact_work_order_checks.sql; the rest are compared with staging, never with the load itself.
*/

USE EnterpriseBI_DW;
GO

-- Precondition: staging must be loaded, or every check below is meaningless.
-- NOEXEC ON skips every later batch; it is switched off again at the end of the script.
IF NOT EXISTS (SELECT 1 FROM stg.aw_sales_person_quota_history)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_sales_territory_history)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_sales_order_header)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_sales_territory)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_work_order)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_product_cost_history)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_product)
BEGIN
    RAISERROR('Staging is empty. Run etl.load_staging first; tests stopped.', 16, 1);
    SET NOEXEC ON;
END;
GO

-- 0. Load the calendar, the dimensions and both facts in one real batch.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_date @batch_id = @batch_id;
EXEC etl.load_dim_product @batch_id = @batch_id;
EXEC etl.load_dim_territory @batch_id = @batch_id;
EXEC etl.load_dim_employee @batch_id = @batch_id;
EXEC etl.load_dim_scrap_reason @batch_id = @batch_id;
EXEC etl.load_fact_sales_quota @batch_id = @batch_id;
EXEC etl.load_fact_work_order @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
SELECT @batch_id AS test_batch_id;
GO

-- 1. fact_sales_quota. Expected: 19 rows, all PASS.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Quota rows = staging rows',
           CAST((SELECT COUNT(*) FROM stg.aw_sales_person_quota_history) AS varchar(60)),
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota) AS varchar(60))
    UNION ALL
    SELECT 'Quota rows (quota check 1)', '163',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota) AS varchar(60))
    UNION ALL
    SELECT 'Salespeople (quota check 1)', '17',
           CAST((SELECT COUNT(DISTINCT salesperson_id) FROM dw.fact_sales_quota) AS varchar(60))
    UNION ALL
    SELECT 'Quota dates: count / first / last (quota check A)', '12 / 2022-05-30 / 2025-02-28',
           (SELECT CONCAT(COUNT(DISTINCT quota_date_key), ' / ', CONVERT(char(10), MIN(d.full_date), 23), ' / ', CONVERT(char(10), MAX(d.full_date), 23))
            FROM dw.fact_sales_quota f JOIN dw.dim_date d ON d.date_key = f.quota_date_key)
    UNION ALL
    SELECT 'Sum of sales_quota = staging',
           CAST((SELECT SUM(SalesQuota) FROM stg.aw_sales_person_quota_history) AS varchar(60)),
           CAST((SELECT SUM(sales_quota) FROM dw.fact_sales_quota) AS varchar(60))
    UNION ALL
    SELECT 'Unknown salesperson (-1)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota WHERE salesperson_key = -1) AS varchar(60))
    UNION ALL
    SELECT 'Unknown territory (-1)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota WHERE territory_key = -1) AS varchar(60))
    UNION ALL
    SELECT 'Territory source history (quota check B)', '132',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota WHERE territory_source = 'history') AS varchar(60))
    UNION ALL
    SELECT 'Territory source nearest_history (7 unmatched rows)', '7',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota WHERE territory_source = 'nearest_history') AS varchar(60))
    UNION ALL
    SELECT 'Territory source region_from_orders (163 - 132 - 7)', '24',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota WHERE territory_source = 'region_from_orders') AS varchar(60))
    UNION ALL
    SELECT 'Territory source unknown', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota WHERE territory_source = 'unknown') AS varchar(60))
    UNION ALL
    SELECT 'Quota rows matching more than one territory period', '0',
           CAST((SELECT COUNT(*) FROM (
                    SELECT q.BusinessEntityID, q.QuotaDate
                    FROM stg.aw_sales_person_quota_history q
                    JOIN stg.aw_sales_territory_history t
                      ON t.BusinessEntityID = q.BusinessEntityID
                     AND q.QuotaDate >= t.StartDate
                     AND (t.EndDate IS NULL OR q.QuotaDate <= t.EndDate)
                    GROUP BY q.BusinessEntityID, q.QuotaDate
                    HAVING COUNT(*) > 1) x) AS varchar(60))
    UNION ALL
    SELECT 'History rows whose territory differs from the covering period', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota f
                 JOIN dw.dim_date d      ON d.date_key = f.quota_date_key
                 JOIN dw.dim_territory t ON t.territory_key = f.territory_key
                 WHERE f.territory_source = 'history'
                   AND NOT EXISTS (SELECT 1 FROM stg.aw_sales_territory_history h
                                   WHERE h.BusinessEntityID = f.salesperson_id
                                     AND d.full_date >= CAST(h.StartDate AS date)
                                     AND (h.EndDate IS NULL OR d.full_date <= CAST(h.EndDate AS date))
                                     AND CAST(h.TerritoryID AS varchar(60)) = t.territory_code)) AS varchar(60))
    UNION ALL
    SELECT 'Nearest rows: salespeople (quota checks: 280 and 284)', '280, 284',
           (SELECT STRING_AGG(CAST(salesperson_id AS varchar(10)), ', ') WITHIN GROUP (ORDER BY salesperson_id)
            FROM (SELECT DISTINCT salesperson_id FROM dw.fact_sales_quota WHERE territory_source = 'nearest_history') x)
    UNION ALL
    SELECT 'Nearest rows not in Northwest (quota checks: both belong to Northwest)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota f
                 JOIN dw.dim_territory t ON t.territory_key = f.territory_key
                 WHERE f.territory_source = 'nearest_history' AND t.territory_name <> N'Northwest') AS varchar(60))
    UNION ALL
    SELECT 'Region rows: salesperson and region (quota check C)', '274 North America; 285 Pacific; 287 Europe',
           (SELECT STRING_AGG(CONCAT(salesperson_id, ' ', region_group), '; ') WITHIN GROUP (ORDER BY salesperson_id)
            FROM (SELECT DISTINCT f.salesperson_id, t.region_group
                  FROM dw.fact_sales_quota f
                  JOIN dw.dim_territory t ON t.territory_key = f.territory_key
                  WHERE f.territory_source = 'region_from_orders' AND t.is_region_level = 1) x)
    UNION ALL
    SELECT 'Rows whose period does not start on the quota date', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota f
                 JOIN dw.dim_date d ON d.date_key = f.quota_date_key
                 WHERE f.quota_period_start <> d.full_date) AS varchar(60))
    UNION ALL
    SELECT 'Periods not exactly 3 months long (D30)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales_quota
                 WHERE DATEDIFF(month, quota_period_start, DATEADD(day, 1, quota_period_end)) <> 3) AS varchar(60))
    UNION ALL
    SELECT 'Last period end (D30)', '2025-05-27',
           (SELECT CONVERT(char(10), MAX(quota_period_end), 23) FROM dw.fact_sales_quota)
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 2. fact_work_order. Expected: 26 rows, all PASS.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Work orders = staging rows',
           CAST((SELECT COUNT(*) FROM stg.aw_work_order) AS varchar(60)),
           CAST((SELECT COUNT(*) FROM dw.fact_work_order) AS varchar(60))
    UNION ALL
    SELECT 'Work orders / products (work order check 1)', '72591 / 238',
           (SELECT CONCAT(COUNT(*), ' / ', COUNT(DISTINCT product_key)) FROM dw.fact_work_order)
    UNION ALL
    SELECT 'Ordered / scrapped units (check 2)', '4507721 / 10651',
           (SELECT CONCAT(SUM(CAST(order_qty AS bigint)), ' / ', SUM(CAST(scrapped_qty AS int))) FROM dw.fact_work_order)
    UNION ALL
    SELECT 'Stocked + scrapped <> ordered', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE stocked_qty + scrapped_qty <> order_qty) AS varchar(60))
    UNION ALL
    SELECT 'Unknown product (-1)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE product_key = -1) AS varchar(60))
    UNION ALL
    SELECT 'Orders with scrap and a real reason (check 2)', '729',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE scrapped_qty > 0 AND scrap_reason_key > 0) AS varchar(60))
    UNION ALL
    SELECT 'Orders without scrap shown as No scrap (-2)', '71862',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE scrapped_qty = 0 AND scrap_reason_key = -2) AS varchar(60))
    UNION ALL
    SELECT 'Unknown scrap reason (-1)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE scrap_reason_key = -1) AS varchar(60))
    UNION ALL
    SELECT 'Scrap reasons used (check 3)', '16',
           CAST((SELECT COUNT(DISTINCT scrap_reason_key) FROM dw.fact_work_order WHERE scrap_reason_key > 0) AS varchar(60))
    UNION ALL
    SELECT 'Open work orders, no end date (check 4)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE end_date_key IS NULL) AS varchar(60))
    UNION ALL
    SELECT 'Finished late (check 4)', '22790',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE is_finished_late = 1) AS varchar(60))
    UNION ALL
    SELECT 'Days to finish: lowest / highest (check 4)', '10 / 32',
           (SELECT CONCAT(MIN(days_to_finish), ' / ', MAX(days_to_finish)) FROM dw.fact_work_order)
    UNION ALL
    SELECT 'Due date not start + 11 days (check 4)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order f
                 JOIN dw.dim_date s ON s.date_key = f.start_date_key
                 JOIN dw.dim_date u ON u.date_key = f.due_date_key
                 WHERE DATEDIFF(day, s.full_date, u.full_date) <> 11) AS varchar(60))
    UNION ALL
    SELECT 'Late with days_late not above 0, or on time with days_late not 0', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order
                 WHERE (is_finished_late = 1 AND days_late <= 0) OR (is_finished_late = 0 AND days_late <> 0)) AS varchar(60))
    UNION ALL
    SELECT 'Last end date (check 4)', '2025-06-16',
           (SELECT CONVERT(char(10), MAX(d.full_date), 23) FROM dw.fact_work_order f JOIN dw.dim_date d ON d.date_key = f.end_date_key)
    UNION ALL
    SELECT 'Cost source history (check 6)', '35297',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE cost_source = 'history') AS varchar(60))
    UNION ALL
    SELECT 'Cost source carried_back (cost gap check)', '7307',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE cost_source = 'carried_back') AS varchar(60))
    UNION ALL
    SELECT 'Cost source carried_forward (cost gap check)', '6439',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE cost_source = 'carried_forward') AS varchar(60))
    UNION ALL
    SELECT 'Cost source standard_cost = staging (no history, StandardCost above 0)',
           CAST((SELECT COUNT(*) FROM stg.aw_work_order w JOIN stg.aw_product p ON p.ProductID = w.ProductID
                 WHERE p.StandardCost > 0
                   AND NOT EXISTS (SELECT 1 FROM stg.aw_product_cost_history c WHERE c.ProductID = w.ProductID)) AS varchar(60)),
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE cost_source = 'standard_cost') AS varchar(60))
    UNION ALL
    SELECT 'standard_cost + unknown (cost gap check: 23,050 + 498)', '23548',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE cost_source IN ('standard_cost', 'unknown')) AS varchar(60))
    UNION ALL
    SELECT 'Rows where unit cost is empty exactly when the source is unknown', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order
                 WHERE (unit_cost IS NULL AND cost_source <> 'unknown') OR (unit_cost IS NOT NULL AND cost_source = 'unknown')) AS varchar(60))
    UNION ALL
    SELECT 'History rows whose cost differs from the period containing the start date', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order f
                 JOIN stg.aw_work_order w ON w.WorkOrderID = f.work_order_id
                 WHERE f.cost_source = 'history'
                   AND NOT EXISTS (SELECT 1 FROM stg.aw_product_cost_history c
                                   WHERE c.ProductID = w.ProductID
                                     AND w.StartDate >= c.StartDate
                                     AND (c.EndDate IS NULL OR w.StartDate <= c.EndDate)
                                     AND c.StandardCost = f.unit_cost)) AS varchar(60))
    UNION ALL
    SELECT 'Carried-forward rows inside a gap (a later period exists)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order f
                 JOIN stg.aw_work_order w ON w.WorkOrderID = f.work_order_id
                 WHERE f.cost_source = 'carried_forward'
                   AND EXISTS (SELECT 1 FROM stg.aw_product_cost_history c
                               WHERE c.ProductID = w.ProductID AND c.StartDate > w.StartDate)) AS varchar(60))
    UNION ALL
    SELECT 'Scrapped units with / without a cost (component check)', '2282 / 8369',
           (SELECT CONCAT(SUM(CASE WHEN unit_cost IS NOT NULL THEN CAST(scrapped_qty AS int) ELSE 0 END), ' / ',
                          SUM(CASE WHEN unit_cost IS NULL     THEN CAST(scrapped_qty AS int) ELSE 0 END))
            FROM dw.fact_work_order)
    UNION ALL
    SELECT 'Rows without scrap whose scrap_cost is not 0', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order WHERE scrapped_qty = 0 AND ISNULL(scrap_cost, -1) <> 0) AS varchar(60))
    UNION ALL
    SELECT 'Scrap rows where scrap_cost <> unit_cost x scrapped_qty (cost known)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_work_order
                 WHERE scrapped_qty > 0 AND unit_cost IS NOT NULL AND scrap_cost <> unit_cost * scrapped_qty) AS varchar(60))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 3. Information (no pass/fail): work orders by cost source.
SELECT  cost_source,
        COUNT(*)                         AS work_orders,
        SUM(CAST(scrapped_qty AS int))   AS scrapped_units,
        SUM(scrap_cost)                  AS scrap_cost
FROM dw.fact_work_order
GROUP BY cost_source
ORDER BY cost_source;
GO

-- 4. Lineage. Expected: 2 rows, rows_without_lineage = 0, batches = 1.
SELECT 'dw.fact_sales_quota' AS fact,
       SUM(CASE WHEN batch_id IS NULL OR loaded_at IS NULL THEN 1 ELSE 0 END) AS rows_without_lineage,
       COUNT(DISTINCT batch_id) AS batches
FROM dw.fact_sales_quota
UNION ALL
SELECT 'dw.fact_work_order',
       SUM(CASE WHEN batch_id IS NULL OR loaded_at IS NULL THEN 1 ELSE 0 END),
       COUNT(DISTINCT batch_id)
FROM dw.fact_work_order;
GO

-- 5a. Empty staging is refused (D106), quota, inside a transaction that is rolled back.
--     Expected: 1 row, load_result = refused, fact_rows_after = 163, staging_rows_after = 163,
--     open_transactions = 0.
DECLARE @batch_id int, @load_result varchar(20);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRANSACTION;
DELETE FROM stg.aw_sales_person_quota_history;
BEGIN TRY
    EXEC etl.load_fact_sales_quota @batch_id = @batch_id;
    SET @load_result = 'NOT refused';
END TRY
BEGIN CATCH
    SET @load_result = CASE WHEN ERROR_NUMBER() = 50002 THEN 'refused' ELSE 'other error' END;
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';

SELECT  @load_result                                              AS load_result,
        (SELECT COUNT(*) FROM dw.fact_sales_quota)                AS fact_rows_after,
        (SELECT COUNT(*) FROM stg.aw_sales_person_quota_history)  AS staging_rows_after,
        @@TRANCOUNT                                               AS open_transactions;
GO

-- 5b. Empty staging is refused (D106), work orders, same method.
--     Expected: 1 row, load_result = refused, fact_rows_after = 72591, staging_rows_after = 72591,
--     open_transactions = 0.
DECLARE @batch_id int, @load_result varchar(20);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRANSACTION;
DELETE FROM stg.aw_work_order;
BEGIN TRY
    EXEC etl.load_fact_work_order @batch_id = @batch_id;
    SET @load_result = 'NOT refused';
END TRY
BEGIN CATCH
    SET @load_result = CASE WHEN ERROR_NUMBER() = 50002 THEN 'refused' ELSE 'other error' END;
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';

SELECT  @load_result                               AS load_result,
        (SELECT COUNT(*) FROM dw.fact_work_order)  AS fact_rows_after,
        (SELECT COUNT(*) FROM stg.aw_work_order)   AS staging_rows_after,
        @@TRANCOUNT                                AS open_transactions;
GO

-- 6. Re-run gives the same result. Expected: 2 rows, both Succeeded, rows 163 and 72591,
--    rows_from_other_batches 0; load_seconds is information.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_fact_sales_quota @batch_id = @batch_id;
EXEC etl.load_fact_work_order @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  l.step_name, l.status, l.rows_written,
        CASE l.step_name WHEN 'dw.fact_sales_quota' THEN (SELECT COUNT(*) FROM dw.fact_sales_quota WHERE batch_id <> @batch_id)
                         ELSE (SELECT COUNT(*) FROM dw.fact_work_order WHERE batch_id <> @batch_id) END AS rows_from_other_batches,
        DATEDIFF(second, l.started_at, l.ended_at) AS load_seconds
FROM etl.load_log l
WHERE l.batch_id = @batch_id
ORDER BY l.log_id;
GO

-- Switch execution back on (see the precondition at the top).
SET NOEXEC OFF;
GO
