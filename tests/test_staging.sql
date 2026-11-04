/*
  test_staging.sql
  Tests for sql/02_warehouse/03_staging_tables.sql and 04_load_staging.sql.
  Runs one real staging load (a new batch), checks it, then runs a second
  load to prove re-runs give the same result.
  Expected results are written above each check.
*/

USE EnterpriseBI_DW;
GO

-- 0. Run one staging load as a real batch.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_staging @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
GO

-- 1. Row counts: every staging table equals its source
--    (Person: employees only). Expected: 36 rows, all PASS.
WITH counts AS (
SELECT 'stg.aw_sales_order_header' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesOrderHeader) AS source_rows, (SELECT COUNT(*) FROM stg.aw_sales_order_header) AS staging_rows
UNION ALL
SELECT 'stg.aw_sales_order_detail' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesOrderDetail) AS source_rows, (SELECT COUNT(*) FROM stg.aw_sales_order_detail) AS staging_rows
UNION ALL
SELECT 'stg.aw_customer' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.Customer) AS source_rows, (SELECT COUNT(*) FROM stg.aw_customer) AS staging_rows
UNION ALL
SELECT 'stg.aw_store' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.Store) AS source_rows, (SELECT COUNT(*) FROM stg.aw_store) AS staging_rows
UNION ALL
SELECT 'stg.aw_sales_territory' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesTerritory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_sales_territory) AS staging_rows
UNION ALL
SELECT 'stg.aw_sales_person' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesPerson) AS source_rows, (SELECT COUNT(*) FROM stg.aw_sales_person) AS staging_rows
UNION ALL
SELECT 'stg.aw_sales_person_quota_history' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesPersonQuotaHistory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_sales_person_quota_history) AS staging_rows
UNION ALL
SELECT 'stg.aw_sales_territory_history' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesTerritoryHistory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_sales_territory_history) AS staging_rows
UNION ALL
SELECT 'stg.aw_special_offer' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SpecialOffer) AS source_rows, (SELECT COUNT(*) FROM stg.aw_special_offer) AS staging_rows
UNION ALL
SELECT 'stg.aw_person' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Person.Person WHERE PersonType IN ('EM', 'SP')) AS source_rows, (SELECT COUNT(*) FROM stg.aw_person) AS staging_rows
UNION ALL
SELECT 'stg.aw_country_region' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Person.CountryRegion) AS source_rows, (SELECT COUNT(*) FROM stg.aw_country_region) AS staging_rows
UNION ALL
SELECT 'stg.aw_employee' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.Employee) AS source_rows, (SELECT COUNT(*) FROM stg.aw_employee) AS staging_rows
UNION ALL
SELECT 'stg.aw_employee_department_history' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.EmployeeDepartmentHistory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_employee_department_history) AS staging_rows
UNION ALL
SELECT 'stg.aw_employee_pay_history' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.EmployeePayHistory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_employee_pay_history) AS staging_rows
UNION ALL
SELECT 'stg.aw_department' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.Department) AS source_rows, (SELECT COUNT(*) FROM stg.aw_department) AS staging_rows
UNION ALL
SELECT 'stg.aw_shift' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.Shift) AS source_rows, (SELECT COUNT(*) FROM stg.aw_shift) AS staging_rows
UNION ALL
SELECT 'stg.aw_product' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Production.Product) AS source_rows, (SELECT COUNT(*) FROM stg.aw_product) AS staging_rows
UNION ALL
SELECT 'stg.aw_product_subcategory' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Production.ProductSubcategory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_product_subcategory) AS staging_rows
UNION ALL
SELECT 'stg.aw_product_category' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Production.ProductCategory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_product_category) AS staging_rows
UNION ALL
SELECT 'stg.aw_product_cost_history' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Production.ProductCostHistory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_product_cost_history) AS staging_rows
UNION ALL
SELECT 'stg.aw_product_inventory' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Production.ProductInventory) AS source_rows, (SELECT COUNT(*) FROM stg.aw_product_inventory) AS staging_rows
UNION ALL
SELECT 'stg.aw_location' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Production.Location) AS source_rows, (SELECT COUNT(*) FROM stg.aw_location) AS staging_rows
UNION ALL
SELECT 'stg.aw_work_order' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Production.WorkOrder) AS source_rows, (SELECT COUNT(*) FROM stg.aw_work_order) AS staging_rows
UNION ALL
SELECT 'stg.aw_scrap_reason' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Production.ScrapReason) AS source_rows, (SELECT COUNT(*) FROM stg.aw_scrap_reason) AS staging_rows
UNION ALL
SELECT 'stg.aw_purchase_order_header' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.PurchaseOrderHeader) AS source_rows, (SELECT COUNT(*) FROM stg.aw_purchase_order_header) AS staging_rows
UNION ALL
SELECT 'stg.aw_purchase_order_detail' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.PurchaseOrderDetail) AS source_rows, (SELECT COUNT(*) FROM stg.aw_purchase_order_detail) AS staging_rows
UNION ALL
SELECT 'stg.aw_vendor' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.Vendor) AS source_rows, (SELECT COUNT(*) FROM stg.aw_vendor) AS staging_rows
UNION ALL
SELECT 'stg.aw_product_vendor' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.ProductVendor) AS source_rows, (SELECT COUNT(*) FROM stg.aw_product_vendor) AS staging_rows
UNION ALL
SELECT 'stg.aw_ship_method' AS staging_table, (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.ShipMethod) AS source_rows, (SELECT COUNT(*) FROM stg.aw_ship_method) AS staging_rows
UNION ALL
SELECT 'stg.awdw_fact_finance' AS staging_table, (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.FactFinance) AS source_rows, (SELECT COUNT(*) FROM stg.awdw_fact_finance) AS staging_rows
UNION ALL
SELECT 'stg.awdw_dim_account' AS staging_table, (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimAccount) AS source_rows, (SELECT COUNT(*) FROM stg.awdw_dim_account) AS staging_rows
UNION ALL
SELECT 'stg.awdw_dim_organization' AS staging_table, (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimOrganization) AS source_rows, (SELECT COUNT(*) FROM stg.awdw_dim_organization) AS staging_rows
UNION ALL
SELECT 'stg.awdw_dim_department_group' AS staging_table, (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimDepartmentGroup) AS source_rows, (SELECT COUNT(*) FROM stg.awdw_dim_department_group) AS staging_rows
UNION ALL
SELECT 'stg.awdw_dim_scenario' AS staging_table, (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimScenario) AS source_rows, (SELECT COUNT(*) FROM stg.awdw_dim_scenario) AS staging_rows
UNION ALL
SELECT 'stg.awdw_dim_currency' AS staging_table, (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimCurrency) AS source_rows, (SELECT COUNT(*) FROM stg.awdw_dim_currency) AS staging_rows
UNION ALL
SELECT 'stg.awdw_fact_currency_rate' AS staging_table, (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.FactCurrencyRate) AS source_rows, (SELECT COUNT(*) FROM stg.awdw_fact_currency_rate) AS staging_rows
)
SELECT  staging_table, source_rows, staging_rows,
        CASE WHEN source_rows = staging_rows THEN 'PASS' ELSE 'FAIL' END AS result
FROM counts
ORDER BY result, staging_table;
GO

-- 2. Totals of key values equal the source exactly. Expected: all PASS.
WITH totals AS (
    SELECT 'Sales line total' AS measure,
           (SELECT SUM(LineTotal)  FROM AdventureWorks2025.Sales.SalesOrderDetail)        AS source_total,
           (SELECT SUM(LineTotal)  FROM stg.aw_sales_order_detail)                        AS staging_total
    UNION ALL
    SELECT 'Sales order subtotal',
           (SELECT SUM(SubTotal)   FROM AdventureWorks2025.Sales.SalesOrderHeader),
           (SELECT SUM(SubTotal)   FROM stg.aw_sales_order_header)
    UNION ALL
    SELECT 'Purchase line total',
           (SELECT SUM(LineTotal)  FROM AdventureWorks2025.Purchasing.PurchaseOrderDetail),
           (SELECT SUM(LineTotal)  FROM stg.aw_purchase_order_detail)
    UNION ALL
    SELECT 'Purchase freight',
           (SELECT SUM(Freight)    FROM AdventureWorks2025.Purchasing.PurchaseOrderHeader),
           (SELECT SUM(Freight)    FROM stg.aw_purchase_order_header)
    UNION ALL
    SELECT 'Purchase received qty',
           (SELECT SUM(ReceivedQty) FROM AdventureWorks2025.Purchasing.PurchaseOrderDetail),
           (SELECT SUM(ReceivedQty) FROM stg.aw_purchase_order_detail)
    UNION ALL
    SELECT 'Work order scrapped qty',
           (SELECT SUM(ScrappedQty) FROM AdventureWorks2025.Production.WorkOrder),
           (SELECT SUM(ScrappedQty) FROM stg.aw_work_order)
    UNION ALL
    SELECT 'Inventory quantity',
           (SELECT SUM(Quantity)   FROM AdventureWorks2025.Production.ProductInventory),
           (SELECT SUM(Quantity)   FROM stg.aw_product_inventory)
    UNION ALL
    SELECT 'Finance amount',
           (SELECT SUM(CAST(Amount AS decimal(38,4))) FROM AdventureWorksDW2025.dbo.FactFinance),
           (SELECT SUM(CAST(Amount AS decimal(38,4))) FROM stg.awdw_fact_finance)
    UNION ALL
    SELECT 'Exchange average rate',
           (SELECT SUM(CAST(AverageRate AS decimal(38,10))) FROM AdventureWorksDW2025.dbo.FactCurrencyRate),
           (SELECT SUM(CAST(AverageRate AS decimal(38,10))) FROM stg.awdw_fact_currency_rate)
)
SELECT  measure, source_total, staging_total,
        CASE WHEN source_total = staging_total THEN 'PASS' ELSE 'FAIL' END AS result
FROM totals;
GO

-- 3. Data types: every staging column has exactly the source's type,
--    length, precision and scale. NULLs are compared with IS DISTINCT FROM
--    (a first version used ISNULL(x, -9), which failed with an overflow:
--    NUMERIC_PRECISION is tinyint, and ISNULL keeps the first argument's
--    type). OrganizationNode is the planned
--    exception (stored as text). Expected: columns_compared = 194,
--    columns_missing_in_source = 0, and NO rows in the mismatch list.
WITH table_map (staging_table, source_db, source_schema, source_table) AS (
    SELECT * FROM (VALUES
        ('aw_sales_order_header', 'AdventureWorks2025', 'Sales', 'SalesOrderHeader'),
        ('aw_sales_order_detail', 'AdventureWorks2025', 'Sales', 'SalesOrderDetail'),
        ('aw_customer', 'AdventureWorks2025', 'Sales', 'Customer'),
        ('aw_store', 'AdventureWorks2025', 'Sales', 'Store'),
        ('aw_sales_territory', 'AdventureWorks2025', 'Sales', 'SalesTerritory'),
        ('aw_sales_person', 'AdventureWorks2025', 'Sales', 'SalesPerson'),
        ('aw_sales_person_quota_history', 'AdventureWorks2025', 'Sales', 'SalesPersonQuotaHistory'),
        ('aw_sales_territory_history', 'AdventureWorks2025', 'Sales', 'SalesTerritoryHistory'),
        ('aw_special_offer', 'AdventureWorks2025', 'Sales', 'SpecialOffer'),
        ('aw_person', 'AdventureWorks2025', 'Person', 'Person'),
        ('aw_country_region', 'AdventureWorks2025', 'Person', 'CountryRegion'),
        ('aw_employee', 'AdventureWorks2025', 'HumanResources', 'Employee'),
        ('aw_employee_department_history', 'AdventureWorks2025', 'HumanResources', 'EmployeeDepartmentHistory'),
        ('aw_employee_pay_history', 'AdventureWorks2025', 'HumanResources', 'EmployeePayHistory'),
        ('aw_department', 'AdventureWorks2025', 'HumanResources', 'Department'),
        ('aw_shift', 'AdventureWorks2025', 'HumanResources', 'Shift'),
        ('aw_product', 'AdventureWorks2025', 'Production', 'Product'),
        ('aw_product_subcategory', 'AdventureWorks2025', 'Production', 'ProductSubcategory'),
        ('aw_product_category', 'AdventureWorks2025', 'Production', 'ProductCategory'),
        ('aw_product_cost_history', 'AdventureWorks2025', 'Production', 'ProductCostHistory'),
        ('aw_product_inventory', 'AdventureWorks2025', 'Production', 'ProductInventory'),
        ('aw_location', 'AdventureWorks2025', 'Production', 'Location'),
        ('aw_work_order', 'AdventureWorks2025', 'Production', 'WorkOrder'),
        ('aw_scrap_reason', 'AdventureWorks2025', 'Production', 'ScrapReason'),
        ('aw_purchase_order_header', 'AdventureWorks2025', 'Purchasing', 'PurchaseOrderHeader'),
        ('aw_purchase_order_detail', 'AdventureWorks2025', 'Purchasing', 'PurchaseOrderDetail'),
        ('aw_vendor', 'AdventureWorks2025', 'Purchasing', 'Vendor'),
        ('aw_product_vendor', 'AdventureWorks2025', 'Purchasing', 'ProductVendor'),
        ('aw_ship_method', 'AdventureWorks2025', 'Purchasing', 'ShipMethod'),
        ('awdw_fact_finance', 'AdventureWorksDW2025', 'dbo', 'FactFinance'),
        ('awdw_dim_account', 'AdventureWorksDW2025', 'dbo', 'DimAccount'),
        ('awdw_dim_organization', 'AdventureWorksDW2025', 'dbo', 'DimOrganization'),
        ('awdw_dim_department_group', 'AdventureWorksDW2025', 'dbo', 'DimDepartmentGroup'),
        ('awdw_dim_scenario', 'AdventureWorksDW2025', 'dbo', 'DimScenario'),
        ('awdw_dim_currency', 'AdventureWorksDW2025', 'dbo', 'DimCurrency'),
        ('awdw_fact_currency_rate', 'AdventureWorksDW2025', 'dbo', 'FactCurrencyRate')
    ) v (staging_table, source_db, source_schema, source_table)
),
source_columns AS (
    SELECT 'AdventureWorks2025' AS source_db, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
           CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION
    FROM AdventureWorks2025.INFORMATION_SCHEMA.COLUMNS
    UNION ALL
    SELECT 'AdventureWorksDW2025', TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
           CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION
    FROM AdventureWorksDW2025.INFORMATION_SCHEMA.COLUMNS
),
staging_columns AS (
    SELECT  m.staging_table, m.source_db, m.source_schema, m.source_table,
            c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH,
            c.NUMERIC_PRECISION, c.NUMERIC_SCALE, c.DATETIME_PRECISION
    FROM INFORMATION_SCHEMA.COLUMNS c
    JOIN table_map m ON m.staging_table = c.TABLE_NAME
    WHERE c.TABLE_SCHEMA = 'stg'
      AND c.COLUMN_NAME NOT IN ('batch_id', 'loaded_at', 'OrganizationNode', 'ParentOrganizationNode')
),
compared AS (
    SELECT  s.staging_table, s.COLUMN_NAME,
            s.DATA_TYPE AS staging_type, src.DATA_TYPE AS source_type,
            CASE WHEN src.COLUMN_NAME IS NULL THEN 'missing in source'
                 WHEN s.DATA_TYPE <> src.DATA_TYPE
                   OR s.CHARACTER_MAXIMUM_LENGTH IS DISTINCT FROM src.CHARACTER_MAXIMUM_LENGTH
                   OR s.NUMERIC_PRECISION IS DISTINCT FROM src.NUMERIC_PRECISION
                   OR s.NUMERIC_SCALE IS DISTINCT FROM src.NUMERIC_SCALE
                   OR s.DATETIME_PRECISION IS DISTINCT FROM src.DATETIME_PRECISION
                 THEN 'type differs'
                 ELSE 'match' END AS outcome
    FROM staging_columns s
    LEFT JOIN source_columns src
           ON src.source_db = s.source_db AND src.TABLE_SCHEMA = s.source_schema
          AND src.TABLE_NAME = s.source_table AND src.COLUMN_NAME = s.COLUMN_NAME
)
SELECT  COUNT(*)                                                     AS columns_compared,
        SUM(CASE WHEN outcome = 'match'             THEN 1 ELSE 0 END) AS columns_matching,
        SUM(CASE WHEN outcome = 'missing in source' THEN 1 ELSE 0 END) AS columns_missing_in_source,
        SUM(CASE WHEN outcome = 'type differs'      THEN 1 ELSE 0 END) AS columns_type_differs
FROM compared;
GO

-- 3b. Mismatch list (expected: no rows). Same comparison, listing problems.
WITH table_map (staging_table, source_db, source_schema, source_table) AS (
    SELECT * FROM (VALUES
        ('aw_sales_order_header', 'AdventureWorks2025', 'Sales', 'SalesOrderHeader'),
        ('aw_sales_order_detail', 'AdventureWorks2025', 'Sales', 'SalesOrderDetail'),
        ('aw_customer', 'AdventureWorks2025', 'Sales', 'Customer'),
        ('aw_store', 'AdventureWorks2025', 'Sales', 'Store'),
        ('aw_sales_territory', 'AdventureWorks2025', 'Sales', 'SalesTerritory'),
        ('aw_sales_person', 'AdventureWorks2025', 'Sales', 'SalesPerson'),
        ('aw_sales_person_quota_history', 'AdventureWorks2025', 'Sales', 'SalesPersonQuotaHistory'),
        ('aw_sales_territory_history', 'AdventureWorks2025', 'Sales', 'SalesTerritoryHistory'),
        ('aw_special_offer', 'AdventureWorks2025', 'Sales', 'SpecialOffer'),
        ('aw_person', 'AdventureWorks2025', 'Person', 'Person'),
        ('aw_country_region', 'AdventureWorks2025', 'Person', 'CountryRegion'),
        ('aw_employee', 'AdventureWorks2025', 'HumanResources', 'Employee'),
        ('aw_employee_department_history', 'AdventureWorks2025', 'HumanResources', 'EmployeeDepartmentHistory'),
        ('aw_employee_pay_history', 'AdventureWorks2025', 'HumanResources', 'EmployeePayHistory'),
        ('aw_department', 'AdventureWorks2025', 'HumanResources', 'Department'),
        ('aw_shift', 'AdventureWorks2025', 'HumanResources', 'Shift'),
        ('aw_product', 'AdventureWorks2025', 'Production', 'Product'),
        ('aw_product_subcategory', 'AdventureWorks2025', 'Production', 'ProductSubcategory'),
        ('aw_product_category', 'AdventureWorks2025', 'Production', 'ProductCategory'),
        ('aw_product_cost_history', 'AdventureWorks2025', 'Production', 'ProductCostHistory'),
        ('aw_product_inventory', 'AdventureWorks2025', 'Production', 'ProductInventory'),
        ('aw_location', 'AdventureWorks2025', 'Production', 'Location'),
        ('aw_work_order', 'AdventureWorks2025', 'Production', 'WorkOrder'),
        ('aw_scrap_reason', 'AdventureWorks2025', 'Production', 'ScrapReason'),
        ('aw_purchase_order_header', 'AdventureWorks2025', 'Purchasing', 'PurchaseOrderHeader'),
        ('aw_purchase_order_detail', 'AdventureWorks2025', 'Purchasing', 'PurchaseOrderDetail'),
        ('aw_vendor', 'AdventureWorks2025', 'Purchasing', 'Vendor'),
        ('aw_product_vendor', 'AdventureWorks2025', 'Purchasing', 'ProductVendor'),
        ('aw_ship_method', 'AdventureWorks2025', 'Purchasing', 'ShipMethod'),
        ('awdw_fact_finance', 'AdventureWorksDW2025', 'dbo', 'FactFinance'),
        ('awdw_dim_account', 'AdventureWorksDW2025', 'dbo', 'DimAccount'),
        ('awdw_dim_organization', 'AdventureWorksDW2025', 'dbo', 'DimOrganization'),
        ('awdw_dim_department_group', 'AdventureWorksDW2025', 'dbo', 'DimDepartmentGroup'),
        ('awdw_dim_scenario', 'AdventureWorksDW2025', 'dbo', 'DimScenario'),
        ('awdw_dim_currency', 'AdventureWorksDW2025', 'dbo', 'DimCurrency'),
        ('awdw_fact_currency_rate', 'AdventureWorksDW2025', 'dbo', 'FactCurrencyRate')
    ) v (staging_table, source_db, source_schema, source_table)
),
source_columns AS (
    SELECT 'AdventureWorks2025' AS source_db, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
           CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION
    FROM AdventureWorks2025.INFORMATION_SCHEMA.COLUMNS
    UNION ALL
    SELECT 'AdventureWorksDW2025', TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
           CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION
    FROM AdventureWorksDW2025.INFORMATION_SCHEMA.COLUMNS
)
SELECT  c.TABLE_NAME AS staging_table, c.COLUMN_NAME,
        c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH, c.NUMERIC_PRECISION, c.NUMERIC_SCALE,
        src.DATA_TYPE AS source_type, src.CHARACTER_MAXIMUM_LENGTH AS source_length,
        src.NUMERIC_PRECISION AS source_precision, src.NUMERIC_SCALE AS source_scale
FROM INFORMATION_SCHEMA.COLUMNS c
JOIN table_map m ON m.staging_table = c.TABLE_NAME
LEFT JOIN source_columns src
       ON src.source_db = m.source_db AND src.TABLE_SCHEMA = m.source_schema
      AND src.TABLE_NAME = m.source_table AND src.COLUMN_NAME = c.COLUMN_NAME
WHERE c.TABLE_SCHEMA = 'stg'
  AND c.COLUMN_NAME NOT IN ('batch_id', 'loaded_at', 'OrganizationNode', 'ParentOrganizationNode')
  AND (   src.COLUMN_NAME IS NULL
       OR c.DATA_TYPE <> src.DATA_TYPE
       OR c.CHARACTER_MAXIMUM_LENGTH IS DISTINCT FROM src.CHARACTER_MAXIMUM_LENGTH
       OR c.NUMERIC_PRECISION IS DISTINCT FROM src.NUMERIC_PRECISION
       OR c.NUMERIC_SCALE IS DISTINCT FROM src.NUMERIC_SCALE
       OR c.DATETIME_PRECISION IS DISTINCT FROM src.DATETIME_PRECISION);
GO

-- 4. Hierarchy text: every employee has a node path except the top one,
--    and everyone with a node has a parent path. Expected: 290 employees,
--    1 without node, 289 with a parent path.
SELECT  COUNT(*)                                                    AS employees,
        SUM(CASE WHEN OrganizationNode IS NULL THEN 1 ELSE 0 END)   AS without_node,
        SUM(CASE WHEN ParentOrganizationNode IS NOT NULL THEN 1 ELSE 0 END) AS with_parent_path
FROM stg.aw_employee;
GO

-- 5. Log of the latest batch. Expected: 36 steps, all Succeeded,
--    rows written = rows read, batch Succeeded.
WITH latest AS (SELECT MAX(batch_id) AS batch_id FROM etl.load_batch)
SELECT  b.batch_id, b.status AS batch_status,
        COUNT(l.log_id)                                              AS steps,
        SUM(CASE WHEN l.status = 'Succeeded' THEN 1 ELSE 0 END)     AS steps_succeeded,
        SUM(CASE WHEN l.rows_read = l.rows_written THEN 1 ELSE 0 END) AS steps_counts_equal,
        SUM(l.rows_written)                                          AS total_rows_written
FROM latest x
JOIN etl.load_batch b ON b.batch_id = x.batch_id
JOIN etl.load_log   l ON l.batch_id = b.batch_id
GROUP BY b.batch_id, b.status;
GO

-- 6. Re-run: a second load gives exactly the same row counts (no duplicates).
--    Expected: tables_compared = 36, tables_changed = 0.
IF OBJECT_ID('tempdb..#before') IS NOT NULL DROP TABLE #before;
SELECT t.name AS table_name, SUM(p.rows) AS row_count
INTO #before
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE SCHEMA_NAME(t.schema_id) = 'stg'
GROUP BY t.name;

DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_staging @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  COUNT(*)                                                 AS tables_compared,
        SUM(CASE WHEN b.row_count <> a.row_count THEN 1 ELSE 0 END) AS tables_changed
FROM #before b
JOIN (SELECT t.name AS table_name, SUM(p.rows) AS row_count
      FROM sys.tables t
      JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
      WHERE SCHEMA_NAME(t.schema_id) = 'stg'
      GROUP BY t.name) a
  ON a.table_name = b.table_name;

DROP TABLE #before;
GO