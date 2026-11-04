/*
  test_dim_source.sql
  Tests for the eight source dimensions: sql/02_warehouse/07_dim_product.sql
  to 14_dim_scrap_reason.sql. Needs staging loaded.
  Loads all eight in one real batch, checks them, proves the soft delete
  inside a rolled-back transaction, and re-runs to prove nothing changes.
  Expected results are written above each check.
*/

USE EnterpriseBI_DW;
GO

-- 0. Load the eight dimensions in one real batch.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_product @batch_id = @batch_id;
EXEC etl.load_dim_territory @batch_id = @batch_id;
EXEC etl.load_dim_customer @batch_id = @batch_id;
EXEC etl.load_dim_promotion @batch_id = @batch_id;
EXEC etl.load_dim_ship_method @batch_id = @batch_id;
EXEC etl.load_dim_vendor @batch_id = @batch_id;
EXEC etl.load_dim_location @batch_id = @batch_id;
EXEC etl.load_dim_scrap_reason @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
GO

-- 1. Row counts: source rows (territory: 10 + 3 region-level rows) plus
--    special rows. Expected: 8 rows, all PASS (product 505, territory 14,
--    customer 19,821, promotion 17, ship method 6, vendor 105,
--    location 16, scrap reason 18).
WITH c AS (
SELECT 'dw.dim_product' AS dimension, (SELECT COUNT(*) FROM stg.aw_product) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_product) AS dimension_rows
UNION ALL
SELECT 'dw.dim_territory' AS dimension, (SELECT COUNT(*) FROM stg.aw_sales_territory) + (SELECT COUNT(DISTINCT [Group]) FROM stg.aw_sales_territory) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_territory) AS dimension_rows
UNION ALL
SELECT 'dw.dim_customer' AS dimension, (SELECT COUNT(*) FROM stg.aw_customer) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_customer) AS dimension_rows
UNION ALL
SELECT 'dw.dim_promotion' AS dimension, (SELECT COUNT(*) FROM stg.aw_special_offer) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_promotion) AS dimension_rows
UNION ALL
SELECT 'dw.dim_ship_method' AS dimension, (SELECT COUNT(*) FROM stg.aw_ship_method) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_ship_method) AS dimension_rows
UNION ALL
SELECT 'dw.dim_vendor' AS dimension, (SELECT COUNT(*) FROM stg.aw_vendor) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_vendor) AS dimension_rows
UNION ALL
SELECT 'dw.dim_location' AS dimension, (SELECT COUNT(*) FROM stg.aw_location) AS source_rows, 2 AS special_rows, (SELECT COUNT(*) FROM dw.dim_location) AS dimension_rows
UNION ALL
SELECT 'dw.dim_scrap_reason' AS dimension, (SELECT COUNT(*) FROM stg.aw_scrap_reason) AS source_rows, 2 AS special_rows, (SELECT COUNT(*) FROM dw.dim_scrap_reason) AS dimension_rows
)
SELECT  dimension, source_rows, special_rows, dimension_rows,
        CASE WHEN source_rows + special_rows = dimension_rows THEN 'PASS' ELSE 'FAIL' END AS result
FROM c;
GO

-- 2. Business keys unique. Expected: 8 rows, duplicates = 0.
WITH k (dimension, duplicates) AS (
SELECT 'dw.dim_product', (SELECT COUNT(*) - COUNT(DISTINCT product_id) FROM dw.dim_product WHERE product_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_territory', (SELECT COUNT(*) - COUNT(DISTINCT territory_code) FROM dw.dim_territory WHERE territory_code IS NOT NULL)
UNION ALL
SELECT 'dw.dim_customer', (SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM dw.dim_customer WHERE customer_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_promotion', (SELECT COUNT(*) - COUNT(DISTINCT promotion_id) FROM dw.dim_promotion WHERE promotion_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_ship_method', (SELECT COUNT(*) - COUNT(DISTINCT ship_method_id) FROM dw.dim_ship_method WHERE ship_method_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_vendor', (SELECT COUNT(*) - COUNT(DISTINCT vendor_id) FROM dw.dim_vendor WHERE vendor_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_location', (SELECT COUNT(*) - COUNT(DISTINCT location_id) FROM dw.dim_location WHERE location_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_scrap_reason', (SELECT COUNT(*) - COUNT(DISTINCT scrap_reason_id) FROM dw.dim_scrap_reason WHERE scrap_reason_id IS NOT NULL)
)
SELECT dimension, duplicates, CASE WHEN duplicates = 0 THEN 'PASS' ELSE 'FAIL' END AS result FROM k;
GO

-- 3. Special rows present with their fixed keys. Expected: 10 rows, all PASS.
WITH s (dimension, special_key, expected_row_type, actual_row_type) AS (
SELECT 'dw.dim_product', -1, 'Unknown', (SELECT row_type FROM dw.dim_product WHERE product_key = -1)
UNION ALL
SELECT 'dw.dim_territory', -1, 'Unknown', (SELECT row_type FROM dw.dim_territory WHERE territory_key = -1)
UNION ALL
SELECT 'dw.dim_customer', -1, 'Unknown', (SELECT row_type FROM dw.dim_customer WHERE customer_key = -1)
UNION ALL
SELECT 'dw.dim_promotion', -1, 'Unknown', (SELECT row_type FROM dw.dim_promotion WHERE promotion_key = -1)
UNION ALL
SELECT 'dw.dim_ship_method', -1, 'Unknown', (SELECT row_type FROM dw.dim_ship_method WHERE ship_method_key = -1)
UNION ALL
SELECT 'dw.dim_vendor', -1, 'Unknown', (SELECT row_type FROM dw.dim_vendor WHERE vendor_key = -1)
UNION ALL
SELECT 'dw.dim_location', -1, 'Unknown', (SELECT row_type FROM dw.dim_location WHERE location_key = -1)
UNION ALL
SELECT 'dw.dim_location', -2, 'Not applicable', (SELECT row_type FROM dw.dim_location WHERE location_key = -2)
UNION ALL
SELECT 'dw.dim_scrap_reason', -1, 'Unknown', (SELECT row_type FROM dw.dim_scrap_reason WHERE scrap_reason_key = -1)
UNION ALL
SELECT 'dw.dim_scrap_reason', -2, 'Not applicable', (SELECT row_type FROM dw.dim_scrap_reason WHERE scrap_reason_key = -2)
)
SELECT  dimension, special_key, expected_row_type, actual_row_type,
        CASE WHEN actual_row_type = expected_row_type THEN 'PASS' ELSE 'FAIL' END AS result
FROM s;
GO

-- 4. Rules. Expected: every row PASS.
WITH r (rule_checked, expected_value, actual_value) AS (
    SELECT 'Products labelled Internal parts',              '209',
           CAST((SELECT COUNT(*) FROM dw.dim_product WHERE category = N'Internal parts' AND row_type = 'Source') AS varchar(20))
    UNION ALL
    SELECT 'Internal parts that are finished goods',        '0',
           CAST((SELECT COUNT(*) FROM dw.dim_product WHERE category = N'Internal parts' AND is_finished_good = 1) AS varchar(20))
    UNION ALL
    SELECT 'Products with unknown (NULL) standard cost',    '200',
           CAST((SELECT COUNT(*) FROM dw.dim_product WHERE standard_cost IS NULL AND row_type = 'Source') AS varchar(20))
    UNION ALL
    SELECT 'Products with a zero cost or price left',       '0',
           CAST((SELECT COUNT(*) FROM dw.dim_product WHERE standard_cost = 0 OR list_price = 0) AS varchar(20))
    UNION ALL
    SELECT 'Raw codes left in product line/class/style',    '0',
           CAST((SELECT COUNT(*) FROM dw.dim_product
                 WHERE product_line IN ('R', 'M', 'T', 'S') OR class IN ('H', 'M', 'L') OR style IN ('W', 'M', 'U')) AS varchar(20))
    UNION ALL
    SELECT 'Discontinued products',                         '98',
           CAST((SELECT COUNT(*) FROM dw.dim_product WHERE product_status = 'Discontinued') AS varchar(20))
    UNION ALL
    SELECT 'Region-level territory rows',                   '3',
           CAST((SELECT COUNT(*) FROM dw.dim_territory WHERE is_region_level = 1 AND country_name = N'Multiple') AS varchar(20))
    UNION ALL
    SELECT 'Region group of Australia',                     'Pacific',
           (SELECT region_group FROM dw.dim_territory WHERE territory_name = N'Australia')
    UNION ALL
    SELECT 'Individual labels not = Individual + account',  '0',
           CAST((SELECT COUNT(*) FROM dw.dim_customer
                 WHERE customer_type = 'Individual' AND customer_label <> N'Individual ' + account_number) AS varchar(20))
    UNION ALL
    SELECT 'Customers with orders',                         '19119',
           CAST((SELECT COUNT(*) FROM dw.dim_customer WHERE has_orders = 1) AS varchar(20))
    UNION ALL
    SELECT 'Duplicate labels among ordering stores',        '0',
           CAST((SELECT COUNT(*) - COUNT(DISTINCT customer_label) FROM dw.dim_customer
                 WHERE customer_type = 'Store' AND has_orders = 1) AS varchar(20))
    UNION ALL
    SELECT 'Promotions used',                               '12',
           CAST((SELECT COUNT(*) FROM dw.dim_promotion WHERE was_used = 1) AS varchar(20))
    UNION ALL
    SELECT 'Vendors rated Superior',                        '84',
           CAST((SELECT COUNT(*) FROM dw.dim_vendor WHERE credit_rating_label = 'Superior') AS varchar(20))
    UNION ALL
    SELECT 'Vendors rated Below average',                   '2',
           CAST((SELECT COUNT(*) FROM dw.dim_vendor WHERE credit_rating_label = 'Below average') AS varchar(20))
    UNION ALL
    SELECT 'Storage locations',                             '7',
           CAST((SELECT COUNT(*) FROM dw.dim_location WHERE location_type = 'Storage') AS varchar(20))
    UNION ALL
    SELECT 'Work centre locations',                         '7',
           CAST((SELECT COUNT(*) FROM dw.dim_location WHERE location_type = 'Work centre') AS varchar(20))
    UNION ALL
    SELECT 'Type of Paint Shop',                            'Storage',
           (SELECT location_type FROM dw.dim_location WHERE location_name = N'Paint Shop')
)
SELECT  rule_checked, expected_value, actual_value,
        CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 5. Lineage. Expected: 8 rows, rows_without_lineage = 0.
WITH l (dimension, rows_without_lineage) AS (
SELECT 'dw.dim_product', (SELECT COUNT(*) FROM dw.dim_product WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_territory', (SELECT COUNT(*) FROM dw.dim_territory WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_customer', (SELECT COUNT(*) FROM dw.dim_customer WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_promotion', (SELECT COUNT(*) FROM dw.dim_promotion WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_ship_method', (SELECT COUNT(*) FROM dw.dim_ship_method WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_vendor', (SELECT COUNT(*) FROM dw.dim_vendor WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_location', (SELECT COUNT(*) FROM dw.dim_location WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_scrap_reason', (SELECT COUNT(*) FROM dw.dim_scrap_reason WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
)
SELECT dimension, rows_without_lineage FROM l;
GO

-- 6. Soft delete, inside a transaction that is rolled back:
--    remove one ship method from staging, reload the dimension.
--    Expected: row still there with is_in_source = 0, rows_retired step
--    wrote 1 row; after rollback is_in_source is 1 again.
BEGIN TRANSACTION;

DELETE FROM stg.aw_ship_method WHERE ShipMethodID = 5;

DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_ship_method @batch_id = @batch_id;

SELECT  'inside transaction' AS moment,
        (SELECT COUNT(*) FROM dw.dim_ship_method)                                   AS rows_total,
        (SELECT is_in_source FROM dw.dim_ship_method WHERE ship_method_id = 5)      AS is_in_source_method_5,
        (SELECT rows_written FROM etl.load_log WHERE batch_id = @batch_id)          AS rows_written;

ROLLBACK TRANSACTION;

SELECT  'after rollback' AS moment,
        (SELECT COUNT(*) FROM dw.dim_ship_method)                                   AS rows_total,
        (SELECT is_in_source FROM dw.dim_ship_method WHERE ship_method_id = 5)      AS is_in_source_method_5,
        NULL                                                                        AS rows_written;
GO

-- 7. Re-run: a second load of all eight writes nothing.
--    Expected: 8 steps, all Succeeded, total rows_written = 0.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_product @batch_id = @batch_id;
EXEC etl.load_dim_territory @batch_id = @batch_id;
EXEC etl.load_dim_customer @batch_id = @batch_id;
EXEC etl.load_dim_promotion @batch_id = @batch_id;
EXEC etl.load_dim_ship_method @batch_id = @batch_id;
EXEC etl.load_dim_vendor @batch_id = @batch_id;
EXEC etl.load_dim_location @batch_id = @batch_id;
EXEC etl.load_dim_scrap_reason @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  COUNT(*)                                               AS steps,
        SUM(CASE WHEN status = 'Succeeded' THEN 1 ELSE 0 END)  AS steps_succeeded,
        SUM(rows_written)                                      AS total_rows_written
FROM etl.load_log
WHERE batch_id = @batch_id;
GO
