/*
  test_fact_purchase_inventory_headcount.sql
  Tests for sql/02_warehouse/26_fact_purchase.sql, 27_fact_inventory_current.sql and
  28_fact_headcount_monthly.sql. Needs staging loaded.
  Loads the calendar, the dimensions these facts use and the three facts in one real batch,
  checks them against staging and the design checks, proves that an empty staging is refused,
  and re-runs to prove the result is stable.
  Fixed numbers come from sql/01_design_checks/fact_purchase_checks.sql,
  fact_inventory_current_checks.sql and fact_headcount_monthly_checks.sql; the rest are
  compared with staging, never with the load itself.
*/

USE EnterpriseBI_DW;
GO

-- Precondition: staging must be loaded, or every check below is meaningless.
-- NOEXEC ON skips every later batch; it is switched off again at the end of the script.
IF NOT EXISTS (SELECT 1 FROM stg.aw_purchase_order_detail)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_purchase_order_header)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_product_vendor)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_product_inventory)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_product)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_employee)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_employee_department_history)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_employee_pay_history)
BEGIN
    RAISERROR('Staging is empty. Run etl.load_staging first; tests stopped.', 16, 1);
    SET NOEXEC ON;
END;
GO

-- 0. Load the calendar, the dimensions and the three facts in one real batch.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_date @batch_id = @batch_id;
EXEC etl.load_dim_product @batch_id = @batch_id;
EXEC etl.load_dim_vendor @batch_id = @batch_id;
EXEC etl.load_dim_ship_method @batch_id = @batch_id;
EXEC etl.load_dim_location @batch_id = @batch_id;
EXEC etl.load_dim_department @batch_id = @batch_id;
EXEC etl.load_dim_shift @batch_id = @batch_id;
EXEC etl.load_dim_employee @batch_id = @batch_id;
EXEC etl.load_dim_employee_hr @batch_id = @batch_id;
EXEC etl.load_fact_purchase @batch_id = @batch_id;
EXEC etl.load_fact_inventory_current @batch_id = @batch_id;
EXEC etl.load_fact_headcount_monthly @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
SELECT @batch_id AS test_batch_id;
GO

-- 1. fact_purchase. Expected: 22 rows, all PASS.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Lines = staging lines',
           CAST((SELECT COUNT(*) FROM stg.aw_purchase_order_detail) AS varchar(100)),
           CAST((SELECT COUNT(*) FROM dw.fact_purchase) AS varchar(100))
    UNION ALL
    SELECT 'Lines / orders (purchase check 1)', '8845 / 4012',
           (SELECT CONCAT(COUNT(*), ' / ', COUNT(DISTINCT purchase_order_id)) FROM dw.fact_purchase)
    UNION ALL
    SELECT 'Lines by status (check 4)', 'Approved 57; Complete 8169; Pending 477; Rejected 142',
           (SELECT STRING_AGG(CONCAT(po_status, ' ', lines), '; ') WITHIN GROUP (ORDER BY po_status)
            FROM (SELECT po_status, COUNT(*) AS lines FROM dw.fact_purchase GROUP BY po_status) x)
    UNION ALL
    SELECT 'Lines whose status text differs from the source function (D111)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_purchase f
                 JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = f.purchase_order_id
                 WHERE f.po_status <> AdventureWorks2025.dbo.ufnGetPurchaseOrderStatusText(h.Status)) AS varchar(100))
    UNION ALL
    SELECT 'Unknown product / vendor / buyer / ship method (-1)', '0 / 0 / 0 / 0',
           (SELECT CONCAT(SUM(CASE WHEN product_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN vendor_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN buyer_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN ship_method_key = -1 THEN 1 ELSE 0 END)) FROM dw.fact_purchase)
    UNION ALL
    SELECT 'Lines without a ship date (check 5)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_purchase WHERE ship_date_key IS NULL) AS varchar(100))
    UNION ALL
    SELECT 'Ordered / received / rejected units (check 4, sum of statuses)', '2348637 / 2327299 / 72700',
           (SELECT CONCAT(SUM(CAST(order_qty AS int)), ' / ', CAST(SUM(received_qty) AS decimal(12,0)), ' / ',
                          CAST(SUM(rejected_qty) AS decimal(12,0))) FROM dw.fact_purchase)
    UNION ALL
    SELECT 'Sum of ordered_value = staging LineTotal',
           CAST((SELECT SUM(CAST(LineTotal AS decimal(19,6))) FROM stg.aw_purchase_order_detail) AS varchar(100)),
           CAST((SELECT SUM(ordered_value) FROM dw.fact_purchase) AS varchar(100))
    UNION ALL
    SELECT 'Lines where ordered <> accepted + rejected + short-delivered (check B)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_purchase
                 WHERE ordered_value <> accepted_value + rejected_value + short_delivered_value) AS varchar(100))
    UNION ALL
    SELECT 'Spend (accepted value) in millions (check B)', '61.21',
           CAST((SELECT CAST(SUM(accepted_value) / 1000000 AS decimal(10,2)) FROM dw.fact_purchase) AS varchar(100))
    UNION ALL
    SELECT 'Stocked <> received - rejected (check 3)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_purchase WHERE stocked_qty <> received_qty - rejected_qty) AS varchar(100))
    UNION ALL
    SELECT 'Short-delivered lines / lines with rejects (check 3)', '380 / 563',
           (SELECT CONCAT(SUM(CASE WHEN received_qty < order_qty THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN rejected_qty > 0 THEN 1 ELSE 0 END)) FROM dw.fact_purchase)
    UNION ALL
    SELECT 'Orders whose allocated freight differs from the header freight (check D)', '0',
           CAST((SELECT COUNT(*) FROM (
                    SELECT f.purchase_order_id
                    FROM dw.fact_purchase f
                    JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = f.purchase_order_id
                    GROUP BY f.purchase_order_id, h.Freight
                    HAVING SUM(f.freight_allocated) <> h.Freight) x) AS varchar(100))
    UNION ALL
    SELECT 'Total allocated freight (check C, header freight)', '1583978.23',
           CAST((SELECT CAST(SUM(freight_allocated) AS decimal(19,2)) FROM dw.fact_purchase) AS varchar(100))
    UNION ALL
    SELECT 'Lines not taking the remainder whose freight differs from their rounded share', '0',
           CAST((SELECT COUNT(*) FROM (
                    SELECT f.freight_allocated, f.ordered_value, h.Freight,
                           SUM(f.ordered_value) OVER (PARTITION BY f.purchase_order_id) AS order_value,
                           ROW_NUMBER() OVER (PARTITION BY f.purchase_order_id
                                              ORDER BY f.ordered_value DESC, f.purchase_order_line_id ASC) AS size_rank
                    FROM dw.fact_purchase f
                    JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = f.purchase_order_id) x
                 WHERE size_rank > 1
                   AND freight_allocated <> ROUND(CAST(ordered_value AS decimal(38,10)) / NULLIF(CAST(order_value AS decimal(38,10)), 0)
                                                  * CAST(Freight AS decimal(38,10)), 2)) AS varchar(100))
    UNION ALL
    SELECT 'Lines with a due date before the order date / their orders (check A, D45)', '7 / 4003, 4006',
           (SELECT CONCAT(COUNT(*), ' / ', (SELECT STRING_AGG(CAST(purchase_order_id AS varchar(10)), ', ') WITHIN GROUP (ORDER BY purchase_order_id)
                                             FROM (SELECT DISTINCT purchase_order_id FROM dw.fact_purchase WHERE is_due_date_invalid = 1) o))
            FROM dw.fact_purchase WHERE is_due_date_invalid = 1)
    UNION ALL
    SELECT 'Promised lead days: missing / lowest / highest (check 6)', '0 / 10 / 120',
           (SELECT CONCAT(SUM(CASE WHEN promised_lead_days IS NULL THEN 1 ELSE 0 END), ' / ',
                          MIN(promised_lead_days), ' / ', MAX(promised_lead_days)) FROM dw.fact_purchase)
    UNION ALL
    SELECT 'Employees placing orders (check 7: 9 + 2 + 1)', '12',
           CAST((SELECT COUNT(DISTINCT buyer_key) FROM dw.fact_purchase) AS varchar(100))
    UNION ALL
    SELECT 'Days to ship: lowest / highest (check 5)', '9 / 25',
           (SELECT CONCAT(MIN(DATEDIFF(day, o.full_date, s.full_date)), ' / ', MAX(DATEDIFF(day, o.full_date, s.full_date)))
            FROM dw.fact_purchase f
            JOIN dw.dim_date o ON o.date_key = f.order_date_key
            JOIN dw.dim_date s ON s.date_key = f.ship_date_key)
    UNION ALL
    SELECT 'Orders linked to a real vendor (check 8: 3,456 + 353 + 203 orders)', '4012',
           CAST((SELECT COUNT(DISTINCT purchase_order_id) FROM dw.fact_purchase f
                 JOIN dw.dim_vendor v ON v.vendor_key = f.vendor_key WHERE v.row_type = 'Source') AS varchar(100))
    UNION ALL
    SELECT 'Date keys that differ from the staging dates', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_purchase f
                 JOIN stg.aw_purchase_order_detail d ON d.PurchaseOrderDetailID = f.purchase_order_line_id
                 JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = d.PurchaseOrderID
                 JOIN dw.dim_date o ON o.date_key = f.order_date_key
                 JOIN dw.dim_date u ON u.date_key = f.due_date_key
                 LEFT JOIN dw.dim_date s ON s.date_key = f.ship_date_key
                 WHERE o.full_date <> CAST(h.OrderDate AS date)
                    OR u.full_date <> CAST(d.DueDate AS date)
                    OR s.full_date IS DISTINCT FROM CAST(h.ShipDate AS date)) AS varchar(100))
    UNION ALL
    SELECT 'Orders with ties for the largest line (query of 10 Nov 2026)', '190',
           CAST((SELECT COUNT(*) FROM (
                    SELECT purchase_order_id FROM (
                        SELECT purchase_order_id,
                               RANK() OVER (PARTITION BY purchase_order_id ORDER BY ordered_value DESC) AS rk
                        FROM dw.fact_purchase) x
                    WHERE rk = 1 GROUP BY purchase_order_id HAVING COUNT(*) > 1) y) AS varchar(100))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 2. fact_inventory_current. Expected: 15 rows, all PASS.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Source rows = staging rows',
           CAST((SELECT COUNT(*) FROM stg.aw_product_inventory) AS varchar(100)),
           CAST((SELECT COUNT(*) FROM dw.fact_inventory_current WHERE is_zero_stock_row = 0) AS varchar(100))
    UNION ALL
    SELECT 'Source rows / products / locations (inventory check 1)', '1069 / 432 / 14',
           (SELECT CONCAT(COUNT(*), ' / ', COUNT(DISTINCT product_key), ' / ', COUNT(DISTINCT location_key))
            FROM dw.fact_inventory_current WHERE is_zero_stock_row = 0)
    UNION ALL
    SELECT 'Zero rows for products on sale without stock (check D, D52)', '54',
           CAST((SELECT COUNT(*) FROM dw.fact_inventory_current WHERE is_zero_stock_row = 1) AS varchar(100))
    UNION ALL
    SELECT 'Zero rows not at No stock location (-2) or not finished goods (check D)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_inventory_current f
                 JOIN dw.dim_product p ON p.product_key = f.product_key
                 WHERE f.is_zero_stock_row = 1 AND (f.location_key <> -2 OR f.quantity <> 0 OR p.is_finished_good = 0)) AS varchar(100))
    UNION ALL
    SELECT 'Unknown product / location (-1)', '0 / 0',
           (SELECT CONCAT(SUM(CASE WHEN product_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN location_key = -1 THEN 1 ELSE 0 END)) FROM dw.fact_inventory_current)
    UNION ALL
    SELECT 'Snapshot dates / date (check 2)', '1 / 2025-08-11',
           (SELECT CONCAT(COUNT(DISTINCT f.snapshot_date_key), ' / ', CONVERT(char(10), MAX(d.full_date), 23))
            FROM dw.fact_inventory_current f JOIN dw.dim_date d ON d.date_key = f.snapshot_date_key)
    UNION ALL
    SELECT 'Total units / source rows with zero stock (check 3)', '335974 / 4',
           (SELECT CONCAT(SUM(quantity), ' / ', SUM(CASE WHEN quantity = 0 AND is_zero_stock_row = 0 THEN 1 ELSE 0 END))
            FROM dw.fact_inventory_current)
    UNION ALL
    SELECT 'Units: standard cost / last purchase price / unknown (checks 6 and E)', '85166 / 228992 / 21816',
           (SELECT CONCAT(SUM(CASE WHEN cost_source = 'standard_cost' THEN quantity ELSE 0 END), ' / ',
                          SUM(CASE WHEN cost_source = 'last_purchase_price' THEN quantity ELSE 0 END), ' / ',
                          SUM(CASE WHEN cost_source = 'unknown' THEN quantity ELSE 0 END))
            FROM dw.fact_inventory_current)
    UNION ALL
    SELECT 'Units with a cost (check E: 93.5%)', '314158',
           CAST((SELECT SUM(quantity) FROM dw.fact_inventory_current WHERE unit_cost IS NOT NULL) AS varchar(100))
    UNION ALL
    SELECT 'Stock value in millions: finished goods (check 6)', '19.23',
           CAST((SELECT CAST(SUM(f.stock_value) / 1000000 AS decimal(10,2)) FROM dw.fact_inventory_current f
                 JOIN dw.dim_product p ON p.product_key = f.product_key WHERE p.is_finished_good = 1) AS varchar(100))
    UNION ALL
    SELECT 'Stock value in millions: internal parts, standard cost / last purchase price (check E)', '0.87 / 8.43',
           (SELECT CONCAT(CAST(SUM(CASE WHEN f.cost_source = 'standard_cost' THEN f.stock_value END) / 1000000 AS decimal(10,2)), ' / ',
                          CAST(SUM(CASE WHEN f.cost_source = 'last_purchase_price' THEN f.stock_value END) / 1000000 AS decimal(10,2)))
            FROM dw.fact_inventory_current f
            JOIN dw.dim_product p ON p.product_key = f.product_key WHERE p.is_finished_good = 0)
    UNION ALL
    SELECT 'Rows where unit cost is empty exactly when the source is unknown', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_inventory_current
                 WHERE (unit_cost IS NULL AND cost_source <> 'unknown') OR (unit_cost IS NOT NULL AND cost_source = 'unknown')) AS varchar(100))
    UNION ALL
    SELECT 'Rows where stock_value <> quantity x unit cost (cost known) or is not 0 at zero quantity', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_inventory_current
                 WHERE (quantity <> 0 AND unit_cost IS NOT NULL AND stock_value <> quantity * unit_cost)
                    OR (quantity = 0 AND ISNULL(stock_value, -1) <> 0)) AS varchar(100))
    UNION ALL
    SELECT 'Standard-cost rows whose cost differs from the product standard cost', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_inventory_current f
                 JOIN stg.aw_product p ON p.ProductID = f.product_id
                 WHERE f.cost_source = 'standard_cost' AND f.unit_cost <> p.StandardCost) AS varchar(100))
    UNION ALL
    SELECT 'Last-purchase-price rows with no purchase line at that price on the latest order date', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_inventory_current f
                 WHERE f.cost_source = 'last_purchase_price'
                   AND NOT EXISTS (SELECT 1 FROM stg.aw_purchase_order_detail d
                                   JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = d.PurchaseOrderID
                                   WHERE d.ProductID = f.product_id AND d.UnitPrice = f.unit_cost
                                     AND h.OrderDate = (SELECT MAX(h2.OrderDate)
                                                        FROM stg.aw_purchase_order_detail d2
                                                        JOIN stg.aw_purchase_order_header h2 ON h2.PurchaseOrderID = d2.PurchaseOrderID
                                                        WHERE d2.ProductID = f.product_id))) AS varchar(100))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 3. fact_headcount_monthly. Expected: 12 rows, all PASS.
--    The row count is compared with an independent count on staging: employees whose hire
--    date + 4,017 days is on or before each month-end from 2022-04-30 to 2025-10-31.
--    The two "at 2025-10-31" rows compare with each employee's latest department and pay row.
--    They expect no department or pay change dated after 2025-10-31 (after the shift); if one
--    of them fails, check that first, before suspecting the code.
WITH r (check_name, expected_value, actual_value) AS (
    SELECT 'Rows = independent count on staging',
           CAST((SELECT COUNT(*) FROM stg.aw_employee e
                 JOIN dw.dim_date d ON d.is_month_end = 1
                                   AND d.full_date BETWEEN '2022-04-30' AND '2025-10-31'
                                   AND DATEADD(day, 4017, e.HireDate) <= d.full_date) AS varchar(100)),
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly) AS varchar(100))
    UNION ALL
    SELECT 'Month-ends: count / first / last (D58)', '43 / 2022-04-30 / 2025-10-31',
           (SELECT CONCAT(COUNT(DISTINCT f.month_end_date_key), ' / ', CONVERT(char(10), MIN(d.full_date), 23), ' / ', CONVERT(char(10), MAX(d.full_date), 23))
            FROM dw.fact_headcount_monthly f JOIN dw.dim_date d ON d.date_key = f.month_end_date_key)
    UNION ALL
    SELECT 'Headcount at 2022-05-31 / 2023-12-31 / 2024-12-31 / 2025-06-30 (headcount check 5)', '283 / 287 / 290 / 290',
           (SELECT CONCAT(SUM(CASE WHEN month_end_date_key = 20220531 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN month_end_date_key = 20231231 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN month_end_date_key = 20241231 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN month_end_date_key = 20250630 THEN 1 ELSE 0 END))
            FROM dw.fact_headcount_monthly)
    UNION ALL
    SELECT 'Unknown employee / department / shift (-1) (check 5: nobody without a department)', '0 / 0 / 0',
           (SELECT CONCAT(SUM(CASE WHEN employee_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN department_key = -1 THEN 1 ELSE 0 END), ' / ',
                          SUM(CASE WHEN shift_key = -1 THEN 1 ELSE 0 END)) FROM dw.fact_headcount_monthly)
    UNION ALL
    SELECT 'Rows without a pay rate (check 3: every employee has one)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly WHERE pay_rate IS NULL) AS varchar(100))
    UNION ALL
    SELECT 'Rows before the hire month (hire date from dim_employee_hr)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly f
                 JOIN dw.dim_employee_hr h ON h.employee_key = f.employee_key
                 JOIN dw.dim_date d ON d.date_key = f.month_end_date_key
                 WHERE h.hire_date > d.full_date) AS varchar(100))
    UNION ALL
    SELECT 'Hired-this-month rows = staging hires from April 2022 to October 2025',
           CAST((SELECT COUNT(*) FROM stg.aw_employee
                 WHERE DATEADD(day, 4017, HireDate) BETWEEN '2022-04-01' AND '2025-10-31') AS varchar(100)),
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly WHERE is_hired_this_month = 1) AS varchar(100))
    UNION ALL
    SELECT 'Hire-month rows with tenure not 0', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly WHERE is_hired_this_month = 1 AND tenure_months <> 0) AS varchar(100))
    UNION ALL
    SELECT 'Department at 2025-10-31 differs from the open period in staging', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly f
                 JOIN dw.dim_department dd ON dd.department_key = f.department_key
                 JOIN stg.aw_employee_department_history h ON h.BusinessEntityID = f.employee_id AND h.EndDate IS NULL
                 WHERE f.month_end_date_key = 20251031 AND dd.department_id <> h.DepartmentID) AS varchar(100))
    UNION ALL
    SELECT 'Pay rate at 2025-10-31 differs from the latest pay row in staging', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly f
                 JOIN (SELECT BusinessEntityID, Rate,
                              ROW_NUMBER() OVER (PARTITION BY BusinessEntityID ORDER BY RateChangeDate DESC) AS rn
                       FROM stg.aw_employee_pay_history) p ON p.BusinessEntityID = f.employee_id AND p.rn = 1
                 WHERE f.month_end_date_key = 20251031 AND f.pay_rate <> p.Rate) AS varchar(100))
    UNION ALL
    SELECT 'Age at 2025-10-31 outside the age band of dim_employee_hr (D91)', '0',
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly f
                 JOIN dw.dim_employee_hr h ON h.employee_key = f.employee_key
                 WHERE f.month_end_date_key = 20251031
                   AND h.age_band <> CASE WHEN f.age_at_month_end < 30 THEN 'Under 30'
                                          WHEN f.age_at_month_end < 40 THEN '30-39'
                                          WHEN f.age_at_month_end < 50 THEN '40-49'
                                          WHEN f.age_at_month_end < 60 THEN '50-59'
                                          ELSE '60 and over' END) AS varchar(100))
    UNION ALL
    SELECT 'Employees in the snapshot at 2025-10-31 = staging employees',
           CAST((SELECT COUNT(*) FROM stg.aw_employee) AS varchar(100)),
           CAST((SELECT COUNT(*) FROM dw.fact_headcount_monthly WHERE month_end_date_key = 20251031) AS varchar(100))
)
SELECT check_name, expected_value, actual_value,
       CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 4. Information (no pass/fail): inventory by cost source, headcount by month-end (first and last 3).
SELECT  cost_source, COUNT(*) AS rows_, SUM(quantity) AS units, CAST(SUM(stock_value) AS decimal(19,2)) AS stock_value
FROM dw.fact_inventory_current
GROUP BY cost_source
ORDER BY cost_source;

SELECT  d.full_date AS month_end, COUNT(*) AS headcount, SUM(CAST(f.is_hired_this_month AS int)) AS hires,
        CAST(AVG(f.pay_rate) AS decimal(10,2)) AS avg_pay_rate
FROM dw.fact_headcount_monthly f
JOIN dw.dim_date d ON d.date_key = f.month_end_date_key
WHERE d.full_date IN ('2022-04-30', '2022-05-31', '2022-06-30', '2025-08-31', '2025-09-30', '2025-10-31')
GROUP BY d.full_date
ORDER BY d.full_date;
GO

-- 5. Lineage. Expected: 3 rows, rows_without_lineage = 0, batches = 1.
SELECT 'dw.fact_purchase' AS fact,
       SUM(CASE WHEN batch_id IS NULL OR loaded_at IS NULL THEN 1 ELSE 0 END) AS rows_without_lineage,
       COUNT(DISTINCT batch_id) AS batches
FROM dw.fact_purchase
UNION ALL
SELECT 'dw.fact_inventory_current',
       SUM(CASE WHEN batch_id IS NULL OR loaded_at IS NULL THEN 1 ELSE 0 END), COUNT(DISTINCT batch_id)
FROM dw.fact_inventory_current
UNION ALL
SELECT 'dw.fact_headcount_monthly',
       SUM(CASE WHEN batch_id IS NULL OR loaded_at IS NULL THEN 1 ELSE 0 END), COUNT(DISTINCT batch_id)
FROM dw.fact_headcount_monthly;
GO

-- 6a. Empty staging is refused (D106), purchase, inside a transaction that is rolled back.
--     Expected: 1 row, refused, 8845, 8845, 0.
DECLARE @batch_id int, @load_result varchar(20);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
BEGIN TRANSACTION;
DELETE FROM stg.aw_purchase_order_detail;
BEGIN TRY
    EXEC etl.load_fact_purchase @batch_id = @batch_id;
    SET @load_result = 'NOT refused';
END TRY
BEGIN CATCH
    SET @load_result = CASE WHEN ERROR_NUMBER() = 50002 THEN 'refused' ELSE 'other error' END;
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';
SELECT  @load_result AS load_result,
        (SELECT COUNT(*) FROM dw.fact_purchase)              AS fact_rows_after,
        (SELECT COUNT(*) FROM stg.aw_purchase_order_detail)  AS staging_rows_after,
        @@TRANCOUNT                                          AS open_transactions;
GO

-- 6b. Same for inventory. Expected: 1 row, refused, 1123, 1069, 0.
DECLARE @batch_id int, @load_result varchar(20);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
BEGIN TRANSACTION;
DELETE FROM stg.aw_product_inventory;
BEGIN TRY
    EXEC etl.load_fact_inventory_current @batch_id = @batch_id;
    SET @load_result = 'NOT refused';
END TRY
BEGIN CATCH
    SET @load_result = CASE WHEN ERROR_NUMBER() = 50002 THEN 'refused' ELSE 'other error' END;
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';
SELECT  @load_result AS load_result,
        (SELECT COUNT(*) FROM dw.fact_inventory_current)  AS fact_rows_after,
        (SELECT COUNT(*) FROM stg.aw_product_inventory)   AS staging_rows_after,
        @@TRANCOUNT                                       AS open_transactions;
GO

-- 6c. Same for headcount (employees removed). Expected: 1 row, refused, the row count of test 3,
--     290 staging employees, 0.
DECLARE @batch_id int, @load_result varchar(20);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
BEGIN TRANSACTION;
DELETE FROM stg.aw_employee;
BEGIN TRY
    EXEC etl.load_fact_headcount_monthly @batch_id = @batch_id;
    SET @load_result = 'NOT refused';
END TRY
BEGIN CATCH
    SET @load_result = CASE WHEN ERROR_NUMBER() = 50002 THEN 'refused' ELSE 'other error' END;
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';
SELECT  @load_result AS load_result,
        (SELECT COUNT(*) FROM dw.fact_headcount_monthly)  AS fact_rows_after,
        (SELECT COUNT(*) FROM stg.aw_employee)            AS staging_rows_after,
        @@TRANCOUNT                                       AS open_transactions;
GO

-- 7. Re-run gives the same result. Expected: 3 rows, all Succeeded, rows 8845, 1123 and the
--    row count of test 3, rows_from_other_batches 0; load_seconds is information.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_fact_purchase @batch_id = @batch_id;
EXEC etl.load_fact_inventory_current @batch_id = @batch_id;
EXEC etl.load_fact_headcount_monthly @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  l.step_name, l.status, l.rows_written,
        CASE l.step_name
             WHEN 'dw.fact_purchase'          THEN (SELECT COUNT(*) FROM dw.fact_purchase WHERE batch_id <> @batch_id)
             WHEN 'dw.fact_inventory_current' THEN (SELECT COUNT(*) FROM dw.fact_inventory_current WHERE batch_id <> @batch_id)
             ELSE (SELECT COUNT(*) FROM dw.fact_headcount_monthly WHERE batch_id <> @batch_id) END AS rows_from_other_batches,
        DATEDIFF(second, l.started_at, l.ended_at) AS load_seconds
FROM etl.load_log l
WHERE l.batch_id = @batch_id
ORDER BY l.log_id;
GO

-- Switch execution back on (see the precondition at the top).
SET NOEXEC OFF;
GO
