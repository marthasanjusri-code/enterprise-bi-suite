/*
  test_fact_sales.sql
  Tests for sql/02_warehouse/23_fact_sales.sql. Needs staging loaded.
  Loads the calendar, the six dimensions fact_sales uses and the fact in one real
  batch, checks grain, totals, keys and rules against staging, proves that a failed
  load keeps the last good data, and re-runs to prove the result is stable.
  Expected results are written above each check. Fixed numbers come from the design
  checks (sql/01_design_checks/fact_sales_checks.sql) and test B2; the rest are
  compared with staging, never with the load itself.
*/

USE EnterpriseBI_DW;
GO

-- Precondition: staging must be loaded, or every check below is meaningless.
-- NOEXEC ON skips every later batch; it is switched off again at the end of the script.
IF NOT EXISTS (SELECT 1 FROM stg.aw_sales_order_detail)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_sales_order_header)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_product_cost_history)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_product)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_customer)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_employee)
BEGIN
    RAISERROR('Staging is empty. Run etl.load_staging first; tests stopped.', 16, 1);
    SET NOEXEC ON;
END;
GO

-- 0. Load the calendar, the dimensions and the fact in one real batch.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_date @batch_id = @batch_id;
EXEC etl.load_dim_product @batch_id = @batch_id;
EXEC etl.load_dim_territory @batch_id = @batch_id;
EXEC etl.load_dim_customer @batch_id = @batch_id;
EXEC etl.load_dim_promotion @batch_id = @batch_id;
EXEC etl.load_dim_ship_method @batch_id = @batch_id;
EXEC etl.load_dim_employee @batch_id = @batch_id;
EXEC etl.load_fact_sales @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
SELECT @batch_id AS test_batch_id;
GO

-- 1. Grain and totals. Expected: 6 rows, all PASS.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Fact rows = staging order lines',
           CAST((SELECT COUNT(*) FROM stg.aw_sales_order_detail) AS varchar(30)),
           CAST((SELECT COUNT(*) FROM dw.fact_sales) AS varchar(30))
    UNION ALL
    SELECT 'Fact rows (design check 1)', '121317',
           CAST((SELECT COUNT(*) FROM dw.fact_sales) AS varchar(30))
    UNION ALL
    SELECT 'Sum of line_total = staging LineTotal',
           CAST((SELECT SUM(CAST(LineTotal AS decimal(19,6))) FROM stg.aw_sales_order_detail) AS varchar(30)),
           CAST((SELECT SUM(line_total) FROM dw.fact_sales) AS varchar(30))
    UNION ALL
    SELECT 'Sum of line_total to the cent (test B2)', '109846381.40',
           CAST((SELECT CAST(SUM(line_total) AS decimal(19,2)) FROM dw.fact_sales) AS varchar(30))
    UNION ALL
    SELECT 'Sum of order_qty = staging',
           CAST((SELECT SUM(CAST(OrderQty AS int)) FROM stg.aw_sales_order_detail) AS varchar(30)),
           CAST((SELECT SUM(CAST(order_qty AS int)) FROM dw.fact_sales) AS varchar(30))
    UNION ALL
    SELECT 'Orders whose line totals differ from SubTotal', '0',
           CAST((SELECT COUNT(*) FROM (
                    SELECT f.sales_order_id
                    FROM dw.fact_sales f
                    JOIN stg.aw_sales_order_header h ON h.SalesOrderID = f.sales_order_id
                    GROUP BY f.sales_order_id, h.SubTotal
                    HAVING ABS(SUM(f.line_total) - h.SubTotal) >= 0.01) x) AS varchar(30))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 2. Keys. Expected: 10 rows, all PASS.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Unknown product (-1)', '0',     CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE product_key = -1) AS varchar(30))
    UNION ALL
    SELECT 'Unknown customer (-1)', '0',    CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE customer_key = -1) AS varchar(30))
    UNION ALL
    SELECT 'Unknown territory (-1)', '0',   CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE territory_key = -1) AS varchar(30))
    UNION ALL
    SELECT 'Unknown promotion (-1)', '0',   CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE promotion_key = -1) AS varchar(30))
    UNION ALL
    SELECT 'Unknown ship method (-1)', '0', CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE ship_method_key = -1) AS varchar(30))
    UNION ALL
    SELECT 'Unknown salesperson (-1)', '0', CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE salesperson_key = -1) AS varchar(30))
    UNION ALL
    SELECT 'No salesperson (-2) = online lines in staging',
           CAST((SELECT COUNT(*) FROM stg.aw_sales_order_detail d
                 JOIN stg.aw_sales_order_header h ON h.SalesOrderID = d.SalesOrderID
                 WHERE h.OnlineOrderFlag = 1) AS varchar(30)),
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE salesperson_key = -2) AS varchar(30))
    UNION ALL
    SELECT 'Reseller lines with no salesperson', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE channel = 'Reseller' AND salesperson_key IN (-1, -2)) AS varchar(30))
    UNION ALL
    SELECT 'Lines without a ship date = staging',
           CAST((SELECT COUNT(*) FROM stg.aw_sales_order_detail d
                 JOIN stg.aw_sales_order_header h ON h.SalesOrderID = d.SalesOrderID
                 WHERE h.ShipDate IS NULL) AS varchar(30)),
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE ship_date_key IS NULL) AS varchar(30))
    UNION ALL
    SELECT 'Date keys that differ from the staging dates', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales f
                 JOIN stg.aw_sales_order_header h ON h.SalesOrderID = f.sales_order_id
                 JOIN dw.dim_date o ON o.date_key = f.order_date_key
                 JOIN dw.dim_date u ON u.date_key = f.due_date_key
                 LEFT JOIN dw.dim_date s ON s.date_key = f.ship_date_key
                 WHERE o.full_date <> CAST(h.OrderDate AS date)
                    OR u.full_date <> CAST(h.DueDate AS date)
                    OR s.full_date IS DISTINCT FROM CAST(h.ShipDate AS date)) AS varchar(30))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 3. Rules. Expected: 12 rows, all PASS.
--    The cost check uses a different formulation from the load: the period whose
--    StartDate..EndDate range contains the order date (EndDate is inclusive, design check 4).
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'gross_amount - discount_amount <> line_total', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE gross_amount - discount_amount <> line_total) AS varchar(30))
    UNION ALL
    SELECT 'gross_amount <> unit_price x order_qty', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE gross_amount <> unit_price * order_qty) AS varchar(30))
    UNION ALL
    SELECT 'Negative discount_amount', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE discount_amount < 0) AS varchar(30))
    UNION ALL
    SELECT 'gross_margin <> line_total - cost_amount', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE gross_margin <> line_total - cost_amount) AS varchar(30))
    UNION ALL
    SELECT 'Lines with no cost (NULL)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE unit_cost IS NULL) AS varchar(30))
    UNION ALL
    SELECT 'Lines with estimated cost (D26)', '64',
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE is_cost_estimated = 1) AS varchar(30))
    UNION ALL
    SELECT 'Products with estimated cost (D26)', '25',
           CAST((SELECT COUNT(DISTINCT product_key) FROM dw.fact_sales WHERE is_cost_estimated = 1) AS varchar(30))
    UNION ALL
    SELECT 'Non-estimated lines whose cost differs from the period containing the order date', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales f
                 JOIN stg.aw_sales_order_header h ON h.SalesOrderID = f.sales_order_id
                 JOIN stg.aw_sales_order_detail d ON d.SalesOrderDetailID = f.sales_order_line_id
                 WHERE f.is_cost_estimated = 0
                   AND NOT EXISTS (SELECT 1 FROM stg.aw_product_cost_history ch
                                   WHERE ch.ProductID = d.ProductID
                                     AND h.OrderDate >= ch.StartDate
                                     AND (ch.EndDate IS NULL OR h.OrderDate <= ch.EndDate)
                                     AND ch.StandardCost = f.unit_cost)) AS varchar(30))
    UNION ALL
    SELECT 'Lines matching more than one cost period', '0',
           CAST((SELECT COUNT(*) FROM (
                    SELECT d.SalesOrderDetailID
                    FROM stg.aw_sales_order_detail d
                    JOIN stg.aw_sales_order_header h ON h.SalesOrderID = d.SalesOrderID
                    JOIN stg.aw_product_cost_history ch
                      ON ch.ProductID = d.ProductID
                     AND h.OrderDate >= ch.StartDate
                     AND (ch.EndDate IS NULL OR h.OrderDate <= ch.EndDate)
                    GROUP BY d.SalesOrderDetailID
                    HAVING COUNT(*) > 1) x) AS varchar(30))
    UNION ALL
    SELECT 'Online lines = staging online lines',
           CAST((SELECT COUNT(*) FROM stg.aw_sales_order_detail d
                 JOIN stg.aw_sales_order_header h ON h.SalesOrderID = d.SalesOrderID
                 WHERE h.OnlineOrderFlag = 1) AS varchar(30)),
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE channel = 'Online') AS varchar(30))
    UNION ALL
    SELECT 'Lines with status Shipped (value profiling: all orders)', '121317',
           CAST((SELECT COUNT(*) FROM dw.fact_sales WHERE order_status = 'Shipped') AS varchar(30))
    UNION ALL
    SELECT 'Lines whose status text differs from the source function (D104)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_sales f
                 JOIN stg.aw_sales_order_header h ON h.SalesOrderID = f.sales_order_id
                 WHERE f.order_status <> AdventureWorks2025.dbo.ufnGetSalesOrderStatusText(h.Status)) AS varchar(30))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 4. Information (no pass/fail): revenue, cost and margin by channel.
SELECT  channel,
        COUNT(*)                                          AS lines,
        CAST(SUM(line_total) AS decimal(19,2))            AS revenue,
        CAST(SUM(cost_amount) AS decimal(19,2))           AS cost,
        CAST(SUM(gross_margin) AS decimal(19,2))          AS gross_margin,
        CAST(100.0 * SUM(gross_margin) / SUM(line_total) AS decimal(5,2)) AS gross_margin_pct
FROM dw.fact_sales
GROUP BY channel
ORDER BY channel;
GO

-- 5. Lineage. Expected: 1 row, rows_without_lineage = 0, batches = 1.
SELECT  SUM(CASE WHEN batch_id IS NULL OR loaded_at IS NULL THEN 1 ELSE 0 END) AS rows_without_lineage,
        COUNT(DISTINCT batch_id)                                             AS batches
FROM dw.fact_sales;
GO

-- 6. A failed load keeps the last good data (D77).
--    A duplicate order line is added to staging (marked with loaded_at = 1900-01-01),
--    so the insert breaks the primary key. Expected: 1 row, load_result = failed,
--    rows_after = 121317, step_status = Failed, duplicates_left = 0.
DECLARE @rows_before int = (SELECT COUNT(*) FROM dw.fact_sales);

INSERT INTO stg.aw_sales_order_detail (SalesOrderID, SalesOrderDetailID, ProductID, SpecialOfferID, OrderQty,
                                       UnitPrice, UnitPriceDiscount, LineTotal, ModifiedDate, batch_id, loaded_at)
SELECT TOP (1) SalesOrderID, SalesOrderDetailID, ProductID, SpecialOfferID, OrderQty,
       UnitPrice, UnitPriceDiscount, LineTotal, ModifiedDate, batch_id, '1900-01-01'
FROM stg.aw_sales_order_detail
ORDER BY SalesOrderDetailID;

DECLARE @batch_id int, @load_result varchar(20);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
BEGIN TRY
    EXEC etl.load_fact_sales @batch_id = @batch_id;
    SET @load_result = 'NOT failed';
END TRY
BEGIN CATCH
    SET @load_result = 'failed';
END CATCH;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';

DELETE FROM stg.aw_sales_order_detail WHERE loaded_at = '1900-01-01';

SELECT  @load_result                                                             AS load_result,
        @rows_before                                                             AS rows_before,
        (SELECT COUNT(*) FROM dw.fact_sales)                                     AS rows_after,
        (SELECT status FROM etl.load_log WHERE batch_id = @batch_id)             AS step_status,
        (SELECT COUNT(*) FROM stg.aw_sales_order_detail WHERE loaded_at = '1900-01-01') AS duplicates_left;
GO

-- 6b. The load refuses an empty staging (D106), inside a transaction that is rolled back.
--     The staging order lines are deleted, then the load runs inside the test's transaction.
--     The load throws error 50002 before it touches the fact and leaves the transaction to
--     the test, whose rollback restores the deleted staging rows.
--     Expected: 1 row, load_result = refused, fact_rows_after = 121317,
--     staging_lines_after = 121317, open_transactions = 0.
DECLARE @batch_id int, @load_result varchar(20);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRANSACTION;
DELETE FROM stg.aw_sales_order_detail;
BEGIN TRY
    EXEC etl.load_fact_sales @batch_id = @batch_id;
    SET @load_result = 'NOT refused';
END TRY
BEGIN CATCH
    SET @load_result = CASE WHEN ERROR_NUMBER() = 50002 THEN 'refused' ELSE 'other error' END;
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';

SELECT  @load_result                                      AS load_result,
        (SELECT COUNT(*) FROM dw.fact_sales)              AS fact_rows_after,
        (SELECT COUNT(*) FROM stg.aw_sales_order_detail)  AS staging_lines_after,
        @@TRANCOUNT                                       AS open_transactions;
GO

-- 7. Re-run gives the same result. Expected: 1 row, Succeeded, rows 121317,
--    revenue 109846381.40, rows_from_other_batches 0; load_seconds is information.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_fact_sales @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  (SELECT status FROM etl.load_log WHERE batch_id = @batch_id)      AS step_status,
        (SELECT rows_written FROM etl.load_log WHERE batch_id = @batch_id) AS rows_written,
        (SELECT CAST(SUM(line_total) AS decimal(19,2)) FROM dw.fact_sales) AS revenue,
        (SELECT COUNT(*) FROM dw.fact_sales WHERE batch_id <> @batch_id)  AS rows_from_other_batches,
        DATEDIFF(second, (SELECT started_at FROM etl.load_log WHERE batch_id = @batch_id),
                         (SELECT ended_at   FROM etl.load_log WHERE batch_id = @batch_id)) AS load_seconds;
GO

-- Switch execution back on (see the precondition at the top).
SET NOEXEC OFF;
GO
