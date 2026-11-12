/*
  31_pipeline.sql
  The nightly pipeline (architecture.md section 2; D76-D78, D100, D118):
    etl.run_pipeline
      start_batch                                   (outside the transaction)
      BEGIN TRANSACTION                             (Option A, D118: all or nothing)
        etl.load_staging                            36 staging tables
        etl.check_staging_counts                    D100: stops at once if any count differs
        etl.load_dimensions                         17 dimensions, in dependency order
        etl.load_facts                              7 facts
        etl.run_quality_checks                      checks in etl.dq_check -> etl.dq_result
      COMMIT when no Error check failed; otherwise ROLLBACK, so the warehouse and staging stay
      exactly as after the last good run. The log rows and check results of the failed run are
      saved before the rollback and written back after it, so the failure stays visible.
      end_batch Succeeded / Failed; a failed run ends with an error so the Agent job shows it.

  Data quality thresholds live in etl.dq_check (D119), not in code. Each check has a rule:
    equals    pass when measured = expected (a known, documented value; a change in either direction warns)
    at_most   pass when measured <= expected (0 = nothing allowed; lower is better)
    at_least  pass when measured >= expected (higher is better, e.g. cost coverage)
  A failed Error check stops the run; a failed Warning check is logged as 'Warn'.
  Safe to re-run: tables are created once, check rows merged, procedures replaced.
*/

USE EnterpriseBI_DW;
GO

-- =====================================================================
-- Data quality check definitions (D119)
-- =====================================================================
IF OBJECT_ID('etl.dq_check') IS NULL
CREATE TABLE etl.dq_check (
    check_code      varchar(10)    NOT NULL CONSTRAINT pk_dq_check PRIMARY KEY,
    check_name      varchar(200)   NOT NULL,
    severity        varchar(10)    NOT NULL CONSTRAINT ck_dq_check_severity CHECK (severity IN ('Error', 'Warning')),
    rule_type       varchar(10)    NOT NULL CONSTRAINT ck_dq_check_rule CHECK (rule_type IN ('equals', 'at_most', 'at_least')),
    expected_value  decimal(18,4)  NOT NULL,
    decision        varchar(50)    NOT NULL,
    is_active       bit            NOT NULL CONSTRAINT df_dq_check_active DEFAULT 1
);
GO

MERGE etl.dq_check AS t
USING (VALUES
    ('E01', 'Staging row counts that differ from the source (36 tables)',                    'Error',   'at_most',  0,      'D10, D100'),
    ('E02', 'Facts whose row count differs from what their staging source implies',          'Error',   'at_most',  0,      'D119'),
    ('E03', 'Fact rows with a required date missing',                                        'Error',   'at_most',  0,      'D22, D102, D108'),
    ('E04', 'Fact rows with key -1 (Unknown) where a value must exist',                      'Error',   'at_most',  0,      'D59'),
    ('E05', 'Purchase lines where ordered <> accepted + rejected + short-delivered value',   'Error',   'at_most',  0,      'D42'),
    ('E06', 'Purchase orders whose allocated freight differs from the header freight',       'Error',   'at_most',  0,      'D44'),
    ('E07', 'Sales orders whose line totals differ from SubTotal',                           'Error',   'at_most',  0,      'D14'),
    ('E08', 'Sales lines matching more than one cost period',                                'Error',   'at_most',  0,      'D26'),
    ('E09', 'Finance money rows without a USD amount (missing exchange rate)',               'Error',   'at_most',  0,      'D36'),
    ('W01', 'Lines with a status not seen at design (sales: Shipped; purchase: 4 statuses)', 'Warning', 'at_most',  0,      'D28, D104, D111'),
    ('W02', 'Sales lines shipped after their due date',                                      'Warning', 'at_most',  0,      'D18'),
    ('W03', 'Purchase lines shipped after a valid due date (invalid due dates are in W07)',   'Warning', 'at_most',  0,      'D43, D45'),
    ('W04', 'Rows with an optional date empty (unshipped orders, open work orders)',         'Warning', 'at_most',  0,      'D102, D108'),
    ('W05', 'Sales lines with estimated cost',                                               'Warning', 'equals',   64,     'D26'),
    ('W06', 'Sales lines on a discounted offer with no discount',                            'Warning', 'equals',   2151,   'D66'),
    ('W07', 'Purchase lines with a due date before the order date',                          'Warning', 'equals',   7,      'D45'),
    ('W08', 'Pending or Approved purchase lines already holding received goods',             'Warning', 'at_most',  534,    'D42'),
    ('W09', 'Quota rows with territory_source unknown',                                      'Warning', 'at_most',  0,      'D32'),
    ('W10', 'Salespeople with orders but no quota',                                          'Warning', 'at_most',  0,      'D32'),
    ('W11', 'Corporate finance rows equal to their children''s total',                       'Warning', 'equals',   342,    'D35'),
    ('W12', 'Scrap cost coverage, % of scrapped units with a cost',                          'Warning', 'at_least', 21.4,   'D46'),
    ('W13', 'Stock value coverage, % of stock units with a cost',                            'Warning', 'at_least', 93.5,   'D53'),
    ('W14', 'Sales lines with no cost',                                                      'Warning', 'at_most',  0,      'D17, D26'),
    ('W15', 'Purchase lines received more than ordered',                                     'Warning', 'at_most',  0,      'D42'),
    ('W16', 'Finance rows on units without a region group',                                  'Warning', 'at_most',  0,      'D95'),
    ('W17', 'Region groups without a regional manager, or managers of a region that does not exist', 'Warning', 'at_most', 0, 'D71, D73'),
    ('W18', 'Headcount rows without a pay rate',                                             'Warning', 'at_most',  0,      'D55')
) AS s (check_code, check_name, severity, rule_type, expected_value, decision)
ON t.check_code = s.check_code
WHEN MATCHED THEN UPDATE SET check_name = s.check_name, severity = s.severity, rule_type = s.rule_type,
                             expected_value = s.expected_value, decision = s.decision
WHEN NOT MATCHED THEN INSERT (check_code, check_name, severity, rule_type, expected_value, decision)
                      VALUES (s.check_code, s.check_name, s.severity, s.rule_type, s.expected_value, s.decision);
GO

-- =====================================================================
-- Writes one result row from a measured value and the rule in etl.dq_check.
-- =====================================================================
CREATE OR ALTER PROCEDURE etl.record_dq_result
    @batch_id    int,
    @check_code  varchar(10),
    @measured    decimal(18,4),
    @details     nvarchar(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.dq_result (batch_id, check_name, severity, measured_value, expected_value, status, details)
    SELECT  @batch_id,
            c.check_code + ' ' + c.check_name,
            c.severity,
            @measured,
            CONCAT(c.rule_type, ' ', CAST(c.expected_value AS varchar(30))),
            CASE WHEN (c.rule_type = 'equals'   AND @measured =  c.expected_value)
                   OR (c.rule_type = 'at_most'  AND @measured <= c.expected_value)
                   OR (c.rule_type = 'at_least' AND @measured >= c.expected_value) THEN 'Pass'
                 WHEN c.severity = 'Error' THEN 'Fail'
                 ELSE 'Warn' END,
            @details
    FROM etl.dq_check c
    WHERE c.check_code = @check_code AND c.is_active = 1;
END;
GO

-- =====================================================================
-- D100: staging row counts against the source, right after the staging load.
-- Same 36 tables and source filters as tests/test_staging.sql test 1.
-- =====================================================================
CREATE OR ALTER PROCEDURE etl.check_staging_counts
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log_id int, @differ int, @details nvarchar(4000);

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'check: staging row counts', @log_id OUTPUT;

        SELECT staging_table, source_rows, staging_rows
        INTO #counts
        FROM (
        SELECT 'stg.aw_sales_order_header', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesOrderHeader), (SELECT COUNT(*) FROM stg.aw_sales_order_header)
        UNION ALL
        SELECT 'stg.aw_sales_order_detail', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesOrderDetail), (SELECT COUNT(*) FROM stg.aw_sales_order_detail)
        UNION ALL
        SELECT 'stg.aw_customer', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.Customer), (SELECT COUNT(*) FROM stg.aw_customer)
        UNION ALL
        SELECT 'stg.aw_store', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.Store), (SELECT COUNT(*) FROM stg.aw_store)
        UNION ALL
        SELECT 'stg.aw_sales_territory', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesTerritory), (SELECT COUNT(*) FROM stg.aw_sales_territory)
        UNION ALL
        SELECT 'stg.aw_sales_person', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesPerson), (SELECT COUNT(*) FROM stg.aw_sales_person)
        UNION ALL
        SELECT 'stg.aw_sales_person_quota_history', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesPersonQuotaHistory), (SELECT COUNT(*) FROM stg.aw_sales_person_quota_history)
        UNION ALL
        SELECT 'stg.aw_sales_territory_history', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SalesTerritoryHistory), (SELECT COUNT(*) FROM stg.aw_sales_territory_history)
        UNION ALL
        SELECT 'stg.aw_special_offer', (SELECT COUNT(*) FROM AdventureWorks2025.Sales.SpecialOffer), (SELECT COUNT(*) FROM stg.aw_special_offer)
        UNION ALL
        SELECT 'stg.aw_person', (SELECT COUNT(*) FROM AdventureWorks2025.Person.Person WHERE PersonType IN ('EM', 'SP')), (SELECT COUNT(*) FROM stg.aw_person)
        UNION ALL
        SELECT 'stg.aw_country_region', (SELECT COUNT(*) FROM AdventureWorks2025.Person.CountryRegion), (SELECT COUNT(*) FROM stg.aw_country_region)
        UNION ALL
        SELECT 'stg.aw_employee', (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.Employee), (SELECT COUNT(*) FROM stg.aw_employee)
        UNION ALL
        SELECT 'stg.aw_employee_department_history', (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.EmployeeDepartmentHistory), (SELECT COUNT(*) FROM stg.aw_employee_department_history)
        UNION ALL
        SELECT 'stg.aw_employee_pay_history', (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.EmployeePayHistory), (SELECT COUNT(*) FROM stg.aw_employee_pay_history)
        UNION ALL
        SELECT 'stg.aw_department', (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.Department), (SELECT COUNT(*) FROM stg.aw_department)
        UNION ALL
        SELECT 'stg.aw_shift', (SELECT COUNT(*) FROM AdventureWorks2025.HumanResources.Shift), (SELECT COUNT(*) FROM stg.aw_shift)
        UNION ALL
        SELECT 'stg.aw_product', (SELECT COUNT(*) FROM AdventureWorks2025.Production.Product), (SELECT COUNT(*) FROM stg.aw_product)
        UNION ALL
        SELECT 'stg.aw_product_subcategory', (SELECT COUNT(*) FROM AdventureWorks2025.Production.ProductSubcategory), (SELECT COUNT(*) FROM stg.aw_product_subcategory)
        UNION ALL
        SELECT 'stg.aw_product_category', (SELECT COUNT(*) FROM AdventureWorks2025.Production.ProductCategory), (SELECT COUNT(*) FROM stg.aw_product_category)
        UNION ALL
        SELECT 'stg.aw_product_cost_history', (SELECT COUNT(*) FROM AdventureWorks2025.Production.ProductCostHistory), (SELECT COUNT(*) FROM stg.aw_product_cost_history)
        UNION ALL
        SELECT 'stg.aw_product_inventory', (SELECT COUNT(*) FROM AdventureWorks2025.Production.ProductInventory), (SELECT COUNT(*) FROM stg.aw_product_inventory)
        UNION ALL
        SELECT 'stg.aw_location', (SELECT COUNT(*) FROM AdventureWorks2025.Production.Location), (SELECT COUNT(*) FROM stg.aw_location)
        UNION ALL
        SELECT 'stg.aw_work_order', (SELECT COUNT(*) FROM AdventureWorks2025.Production.WorkOrder), (SELECT COUNT(*) FROM stg.aw_work_order)
        UNION ALL
        SELECT 'stg.aw_scrap_reason', (SELECT COUNT(*) FROM AdventureWorks2025.Production.ScrapReason), (SELECT COUNT(*) FROM stg.aw_scrap_reason)
        UNION ALL
        SELECT 'stg.aw_purchase_order_header', (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.PurchaseOrderHeader), (SELECT COUNT(*) FROM stg.aw_purchase_order_header)
        UNION ALL
        SELECT 'stg.aw_purchase_order_detail', (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.PurchaseOrderDetail), (SELECT COUNT(*) FROM stg.aw_purchase_order_detail)
        UNION ALL
        SELECT 'stg.aw_vendor', (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.Vendor), (SELECT COUNT(*) FROM stg.aw_vendor)
        UNION ALL
        SELECT 'stg.aw_product_vendor', (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.ProductVendor), (SELECT COUNT(*) FROM stg.aw_product_vendor)
        UNION ALL
        SELECT 'stg.aw_ship_method', (SELECT COUNT(*) FROM AdventureWorks2025.Purchasing.ShipMethod), (SELECT COUNT(*) FROM stg.aw_ship_method)
        UNION ALL
        SELECT 'stg.awdw_fact_finance', (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.FactFinance), (SELECT COUNT(*) FROM stg.awdw_fact_finance)
        UNION ALL
        SELECT 'stg.awdw_dim_account', (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimAccount), (SELECT COUNT(*) FROM stg.awdw_dim_account)
        UNION ALL
        SELECT 'stg.awdw_dim_organization', (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimOrganization), (SELECT COUNT(*) FROM stg.awdw_dim_organization)
        UNION ALL
        SELECT 'stg.awdw_dim_department_group', (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimDepartmentGroup), (SELECT COUNT(*) FROM stg.awdw_dim_department_group)
        UNION ALL
        SELECT 'stg.awdw_dim_scenario', (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimScenario), (SELECT COUNT(*) FROM stg.awdw_dim_scenario)
        UNION ALL
        SELECT 'stg.awdw_dim_currency', (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.DimCurrency), (SELECT COUNT(*) FROM stg.awdw_dim_currency)
        UNION ALL
        SELECT 'stg.awdw_fact_currency_rate', (SELECT COUNT(*) FROM AdventureWorksDW2025.dbo.FactCurrencyRate), (SELECT COUNT(*) FROM stg.awdw_fact_currency_rate)
        ) c (staging_table, source_rows, staging_rows);

        SELECT @differ  = COUNT(*),
               @details = STRING_AGG(CONCAT(staging_table, ' source ', source_rows, ' staging ', staging_rows), '; ')
        FROM #counts
        WHERE source_rows <> staging_rows OR staging_rows = 0;

        EXEC etl.record_dq_result @batch_id, 'E01', @differ, @details;
        EXEC etl.end_step @log_id, 'Succeeded', 36, @differ;
        SET @log_id = NULL;

        IF @differ > 0
            THROW 50003, 'Staging row counts differ from the source; the run stops before any dimension (D100).', 1;
    END TRY
    BEGIN CATCH
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL AND XACT_STATE() <> -1
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO

-- =====================================================================
-- Dimensions in dependency order (dim_territory before dim_organization).
-- =====================================================================
CREATE OR ALTER PROCEDURE etl.load_dimensions
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;
    EXEC etl.load_dim_date @batch_id = @batch_id;
    EXEC etl.load_dim_product @batch_id = @batch_id;
    EXEC etl.load_dim_territory @batch_id = @batch_id;
    EXEC etl.load_dim_customer @batch_id = @batch_id;
    EXEC etl.load_dim_promotion @batch_id = @batch_id;
    EXEC etl.load_dim_ship_method @batch_id = @batch_id;
    EXEC etl.load_dim_vendor @batch_id = @batch_id;
    EXEC etl.load_dim_location @batch_id = @batch_id;
    EXEC etl.load_dim_scrap_reason @batch_id = @batch_id;
    EXEC etl.load_dim_department @batch_id = @batch_id;
    EXEC etl.load_dim_shift @batch_id = @batch_id;
    EXEC etl.load_dim_employee @batch_id = @batch_id;
    EXEC etl.load_dim_employee_hr @batch_id = @batch_id;
    EXEC etl.load_dim_scenario @batch_id = @batch_id;
    EXEC etl.load_dim_finance_department_group @batch_id = @batch_id;
    EXEC etl.load_dim_organization @batch_id = @batch_id;
    EXEC etl.load_dim_account @batch_id = @batch_id;
END;
GO

CREATE OR ALTER PROCEDURE etl.load_facts
    @batch_id int
AS
BEGIN
    SET NOCOUNT ON;
    EXEC etl.load_fact_sales @batch_id = @batch_id;
    EXEC etl.load_fact_sales_quota @batch_id = @batch_id;
    EXEC etl.load_fact_work_order @batch_id = @batch_id;
    EXEC etl.load_fact_purchase @batch_id = @batch_id;
    EXEC etl.load_fact_inventory_current @batch_id = @batch_id;
    EXEC etl.load_fact_headcount_monthly @batch_id = @batch_id;
    EXEC etl.load_fact_finance @batch_id = @batch_id;
END;
GO

-- =====================================================================
-- Data quality checks E02-E09 and W01-W18 (E01 runs right after staging).
-- Returns the number of failed Error checks.
-- =====================================================================
CREATE OR ALTER PROCEDURE etl.run_quality_checks
    @batch_id     int,
    @error_count  int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log_id int, @m decimal(18,4), @d nvarchar(4000),
            @hr_shift int, @hr_as_of date, @first_month_end date;

    BEGIN TRY
        EXEC etl.start_step @batch_id, 'check: data quality', @log_id OUTPUT;

        -- E02: each fact against what its staging source implies.
        EXEC etl.get_setting_int  'hr_date_shift_days', @hr_shift OUTPUT;
        EXEC etl.get_setting_date 'hr_as_of_date', @hr_as_of OUTPUT;
        SET @first_month_end = EOMONTH((SELECT MIN(d) FROM (
                                   SELECT MIN(CAST(OrderDate AS date)) AS d FROM stg.aw_sales_order_header
                                   UNION ALL SELECT MIN(CAST(OrderDate AS date)) FROM stg.aw_purchase_order_header
                                   UNION ALL SELECT MIN(CAST(StartDate AS date)) FROM stg.aw_work_order) x));

        SELECT fact, expected_rows, actual_rows
        INTO #fact_counts
        FROM (
            SELECT 'fact_sales', (SELECT COUNT(*) FROM stg.aw_sales_order_detail), (SELECT COUNT(*) FROM dw.fact_sales)
            UNION ALL
            SELECT 'fact_sales_quota', (SELECT COUNT(*) FROM stg.aw_sales_person_quota_history), (SELECT COUNT(*) FROM dw.fact_sales_quota)
            UNION ALL
            SELECT 'fact_work_order', (SELECT COUNT(*) FROM stg.aw_work_order), (SELECT COUNT(*) FROM dw.fact_work_order)
            UNION ALL
            SELECT 'fact_purchase', (SELECT COUNT(*) FROM stg.aw_purchase_order_detail), (SELECT COUNT(*) FROM dw.fact_purchase)
            UNION ALL
            SELECT 'fact_inventory_current',
                   (SELECT COUNT(*) FROM stg.aw_product_inventory)
                 + (SELECT COUNT(*) FROM stg.aw_product p
                    WHERE p.SellEndDate IS NULL
                      AND NOT EXISTS (SELECT 1 FROM stg.aw_product_inventory i WHERE i.ProductID = p.ProductID)),
                   (SELECT COUNT(*) FROM dw.fact_inventory_current)
            UNION ALL
            SELECT 'fact_headcount_monthly',
                   (SELECT COUNT(*) FROM stg.aw_employee e
                    JOIN dw.dim_date d ON d.is_month_end = 1
                                      AND d.full_date BETWEEN @first_month_end AND @hr_as_of
                                      AND DATEADD(day, @hr_shift, e.HireDate) <= d.full_date),
                   (SELECT COUNT(*) FROM dw.fact_headcount_monthly)
            UNION ALL
            SELECT 'fact_finance', (SELECT COUNT(*) FROM stg.awdw_fact_finance), (SELECT COUNT(*) FROM dw.fact_finance)
        ) x (fact, expected_rows, actual_rows);

        SELECT @m = COUNT(*), @d = STRING_AGG(CONCAT(fact, ' expected ', expected_rows, ' loaded ', actual_rows), '; ')
        FROM #fact_counts WHERE expected_rows <> actual_rows OR actual_rows = 0;
        EXEC etl.record_dq_result @batch_id, 'E02', @m, @d;

        -- E03: required dates (also enforced by NOT NULL and foreign keys).
        SET @m = (SELECT COUNT(*) FROM dw.fact_sales            WHERE order_date_key IS NULL OR due_date_key IS NULL)
               + (SELECT COUNT(*) FROM dw.fact_purchase         WHERE order_date_key IS NULL OR due_date_key IS NULL)
               + (SELECT COUNT(*) FROM dw.fact_work_order       WHERE start_date_key IS NULL OR due_date_key IS NULL)
               + (SELECT COUNT(*) FROM dw.fact_sales_quota      WHERE quota_date_key IS NULL)
               + (SELECT COUNT(*) FROM dw.fact_inventory_current WHERE snapshot_date_key IS NULL)
               + (SELECT COUNT(*) FROM dw.fact_headcount_monthly WHERE month_end_date_key IS NULL)
               + (SELECT COUNT(*) FROM dw.fact_finance          WHERE period_date_key IS NULL);
        EXEC etl.record_dq_result @batch_id, 'E03', @m, NULL;

        -- E04: unknown keys where a value must exist.
        SELECT fact, unknown_rows
        INTO #unknown
        FROM (
            SELECT 'fact_sales', COUNT(*) FROM dw.fact_sales
            WHERE -1 IN (product_key, customer_key, salesperson_key, territory_key, promotion_key, ship_method_key)
            UNION ALL
            SELECT 'fact_sales_quota', COUNT(*) FROM dw.fact_sales_quota WHERE -1 IN (salesperson_key, territory_key)
            UNION ALL
            SELECT 'fact_work_order', COUNT(*) FROM dw.fact_work_order WHERE -1 IN (product_key, scrap_reason_key)
            UNION ALL
            SELECT 'fact_purchase', COUNT(*) FROM dw.fact_purchase
            WHERE -1 IN (product_key, vendor_key, buyer_key, ship_method_key)
            UNION ALL
            SELECT 'fact_inventory_current', COUNT(*) FROM dw.fact_inventory_current WHERE -1 IN (product_key, location_key)
            UNION ALL
            SELECT 'fact_headcount_monthly', COUNT(*) FROM dw.fact_headcount_monthly
            WHERE -1 IN (employee_key, department_key, shift_key)
            UNION ALL
            SELECT 'fact_finance', COUNT(*) FROM dw.fact_finance
            WHERE -1 IN (organization_key, finance_department_group_key, account_key, scenario_key)
        ) x (fact, unknown_rows);
        SELECT @m = SUM(unknown_rows), @d = STRING_AGG(CASE WHEN unknown_rows > 0 THEN CONCAT(fact, ' ', unknown_rows) END, '; ')
        FROM #unknown;
        EXEC etl.record_dq_result @batch_id, 'E04', @m, @d;

        -- E05-E09: reconciliations.
        SET @m = (SELECT COUNT(*) FROM dw.fact_purchase
                  WHERE ordered_value <> accepted_value + rejected_value + short_delivered_value);
        EXEC etl.record_dq_result @batch_id, 'E05', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM (
                      SELECT f.purchase_order_id FROM dw.fact_purchase f
                      JOIN stg.aw_purchase_order_header h ON h.PurchaseOrderID = f.purchase_order_id
                      GROUP BY f.purchase_order_id, h.Freight
                      HAVING SUM(f.freight_allocated) <> h.Freight) x);
        EXEC etl.record_dq_result @batch_id, 'E06', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM (
                      SELECT f.sales_order_id FROM dw.fact_sales f
                      JOIN stg.aw_sales_order_header h ON h.SalesOrderID = f.sales_order_id
                      GROUP BY f.sales_order_id, h.SubTotal
                      HAVING ABS(SUM(f.line_total) - h.SubTotal) >= 0.01) x);
        EXEC etl.record_dq_result @batch_id, 'E07', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM (
                      SELECT d.SalesOrderDetailID
                      FROM stg.aw_sales_order_detail d
                      JOIN stg.aw_sales_order_header h ON h.SalesOrderID = d.SalesOrderID
                      JOIN stg.aw_product_cost_history ch
                        ON ch.ProductID = d.ProductID AND h.OrderDate >= ch.StartDate
                       AND (ch.EndDate IS NULL OR h.OrderDate <= ch.EndDate)
                      GROUP BY d.SalesOrderDetailID HAVING COUNT(*) > 1) x);
        EXEC etl.record_dq_result @batch_id, 'E08', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_finance f JOIN dw.dim_account a ON a.account_key = f.account_key
                  WHERE a.statement IN ('Balance sheet', 'Income statement') AND f.amount_usd IS NULL);
        SET @d = (SELECT STRING_AGG(CONCAT(currency_code, ' ', n), '; ') FROM (
                      SELECT f.currency_code, COUNT(*) AS n FROM dw.fact_finance f
                      JOIN dw.dim_account a ON a.account_key = f.account_key
                      WHERE a.statement IN ('Balance sheet', 'Income statement') AND f.amount_usd IS NULL
                      GROUP BY f.currency_code) x);
        EXEC etl.record_dq_result @batch_id, 'E09', @m, @d;

        -- W01-W18: warnings.
        SET @m = (SELECT COUNT(*) FROM dw.fact_sales WHERE order_status <> 'Shipped')
               + (SELECT COUNT(*) FROM dw.fact_purchase WHERE po_status NOT IN ('Pending', 'Approved', 'Rejected', 'Complete'));
        SET @d = (SELECT STRING_AGG(CONCAT(s, ' ', n), '; ') FROM (
                      SELECT 'sales ' + order_status AS s, COUNT(*) AS n FROM dw.fact_sales WHERE order_status <> 'Shipped' GROUP BY order_status
                      UNION ALL
                      SELECT 'purchase ' + po_status, COUNT(*) FROM dw.fact_purchase
                      WHERE po_status NOT IN ('Pending', 'Approved', 'Rejected', 'Complete') GROUP BY po_status) x);
        EXEC etl.record_dq_result @batch_id, 'W01', @m, @d;

        SET @m = (SELECT COUNT(*) FROM dw.fact_sales WHERE ship_date_key > due_date_key);
        EXEC etl.record_dq_result @batch_id, 'W02', @m, NULL;

        -- W03 skips the lines with a due date before the order date (D45); W07 reports those.
        SET @m = (SELECT COUNT(*) FROM dw.fact_purchase
                  WHERE ship_date_key > due_date_key AND is_due_date_invalid = 0);
        EXEC etl.record_dq_result @batch_id, 'W03', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_sales WHERE ship_date_key IS NULL)
               + (SELECT COUNT(*) FROM dw.fact_purchase WHERE ship_date_key IS NULL)
               + (SELECT COUNT(*) FROM dw.fact_work_order WHERE end_date_key IS NULL);
        EXEC etl.record_dq_result @batch_id, 'W04', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_sales WHERE is_cost_estimated = 1);
        EXEC etl.record_dq_result @batch_id, 'W05', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_sales f JOIN dw.dim_promotion p ON p.promotion_key = f.promotion_key
                  WHERE p.promotion_id <> 1 AND f.discount_pct = 0);
        EXEC etl.record_dq_result @batch_id, 'W06', @m, N'Reading: any offer other than offer 1 "No Discount" with discount 0';

        SET @m = (SELECT COUNT(*) FROM dw.fact_purchase WHERE is_due_date_invalid = 1);
        EXEC etl.record_dq_result @batch_id, 'W07', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_purchase WHERE po_status IN ('Pending', 'Approved') AND received_qty > 0);
        EXEC etl.record_dq_result @batch_id, 'W08', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_sales_quota WHERE territory_source = 'unknown');
        EXEC etl.record_dq_result @batch_id, 'W09', @m, NULL;

        SET @m = (SELECT COUNT(DISTINCT f.salesperson_key) FROM dw.fact_sales f
                  WHERE f.salesperson_key > 0
                    AND NOT EXISTS (SELECT 1 FROM dw.fact_sales_quota q WHERE q.salesperson_key = f.salesperson_key));
        EXEC etl.record_dq_result @batch_id, 'W10', @m, NULL;

        WITH corp AS (
            SELECT f.organization_key, f.scenario_key, f.account_key, f.source_date, f.amount_local
            FROM dw.fact_finance f
            JOIN dw.dim_finance_department_group g ON g.finance_department_group_key = f.finance_department_group_key
            WHERE g.is_corporate_direct = 1
        ), kids AS (
            SELECT f.organization_key, f.scenario_key, f.account_key, f.source_date, SUM(f.amount_local) AS amount_local
            FROM dw.fact_finance f
            JOIN dw.dim_finance_department_group g ON g.finance_department_group_key = f.finance_department_group_key
            WHERE g.is_corporate_direct = 0 AND g.row_type = 'Source'
            GROUP BY f.organization_key, f.scenario_key, f.account_key, f.source_date
        )
        SELECT @m = COUNT(*)
        FROM corp c
        JOIN kids k ON k.organization_key = c.organization_key AND k.scenario_key = c.scenario_key
                   AND k.account_key = c.account_key AND k.source_date = c.source_date
        WHERE ABS(c.amount_local - k.amount_local) < 0.01;
        EXEC etl.record_dq_result @batch_id, 'W11', @m, NULL;

        SET @m = (SELECT CAST(100.0 * SUM(CASE WHEN unit_cost IS NOT NULL THEN CAST(scrapped_qty AS int) ELSE 0 END)
                              / NULLIF(SUM(CAST(scrapped_qty AS int)), 0) AS decimal(18,4)) FROM dw.fact_work_order);
        EXEC etl.record_dq_result @batch_id, 'W12', @m, NULL;

        SET @m = (SELECT CAST(100.0 * SUM(CASE WHEN unit_cost IS NOT NULL THEN quantity ELSE 0 END)
                              / NULLIF(SUM(quantity), 0) AS decimal(18,4)) FROM dw.fact_inventory_current);
        EXEC etl.record_dq_result @batch_id, 'W13', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_sales WHERE unit_cost IS NULL);
        EXEC etl.record_dq_result @batch_id, 'W14', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_purchase WHERE received_qty > order_qty);
        EXEC etl.record_dq_result @batch_id, 'W15', @m, NULL;

        SET @m = (SELECT COUNT(*) FROM dw.fact_finance f JOIN dw.dim_organization o ON o.organization_key = f.organization_key
                  WHERE o.region_group = N'N/A');
        EXEC etl.record_dq_result @batch_id, 'W16', @m, NULL;

        WITH regions AS (
            SELECT DISTINCT region_group FROM dw.dim_territory
            WHERE row_type IN ('Source', 'Derived') AND is_in_source = 1 AND is_region_level = 1
        ), managers AS (
            SELECT DISTINCT region_group FROM dw.security_user_region WHERE security_role = 'Regional Manager'
        )
        SELECT @m = COUNT(*), @d = STRING_AGG(CONCAT(issue, ': ', region_group), '; ')
        FROM (
            SELECT 'no manager' AS issue, r.region_group FROM regions r
            WHERE NOT EXISTS (SELECT 1 FROM managers m WHERE m.region_group = r.region_group)
            UNION ALL
            SELECT 'region does not exist', m.region_group FROM managers m
            WHERE NOT EXISTS (SELECT 1 FROM regions r WHERE r.region_group = m.region_group)
        ) x;
        EXEC etl.record_dq_result @batch_id, 'W17', @m, @d;

        SET @m = (SELECT COUNT(*) FROM dw.fact_headcount_monthly WHERE pay_rate IS NULL);
        EXEC etl.record_dq_result @batch_id, 'W18', @m, NULL;

        SET @error_count = (SELECT COUNT(*) FROM etl.dq_result WHERE batch_id = @batch_id AND status = 'Fail');

        EXEC etl.end_step @log_id, 'Succeeded', NULL, @error_count;
        SET @log_id = NULL;
    END TRY
    BEGIN CATCH
        DECLARE @message nvarchar(4000) = ERROR_MESSAGE();
        IF @log_id IS NOT NULL AND XACT_STATE() <> -1
            EXEC etl.end_step @log_id, 'Failed', NULL, NULL, @message;
        THROW;
    END CATCH;
END;
GO

-- =====================================================================
-- The whole run (Option A, D118).
-- =====================================================================
CREATE OR ALTER PROCEDURE etl.run_pipeline
    @batch_id int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @@TRANCOUNT > 0
        THROW 50004, 'etl.run_pipeline manages its own transaction; call it outside a transaction.', 1;

    DECLARE @error_count int = 0, @message nvarchar(2048), @failed bit = 0;
    DECLARE @log TABLE (step_name varchar(100), started_at datetime2(0), ended_at datetime2(0),
                        rows_read int, rows_written int, status varchar(10), error_message nvarchar(4000));
    DECLARE @dq  TABLE (check_name varchar(200), severity varchar(10), measured_value decimal(18,4),
                        expected_value varchar(100), status varchar(10), details nvarchar(4000), checked_at datetime2(0));

    EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC etl.load_staging          @batch_id = @batch_id;
        EXEC etl.check_staging_counts  @batch_id = @batch_id;
        EXEC etl.load_dimensions       @batch_id = @batch_id;
        EXEC etl.load_facts            @batch_id = @batch_id;
        EXEC etl.run_quality_checks    @batch_id = @batch_id, @error_count = @error_count OUTPUT;

        IF @error_count > 0
        BEGIN
            SET @failed = 1;
            SET @message = CONCAT(@error_count, ' data quality Error check(s) failed; the run was rolled back (D77, D118).');
        END
    END TRY
    BEGIN CATCH
        SET @failed = 1;
        SET @message = ERROR_MESSAGE();
    END CATCH;

    IF @failed = 0
    BEGIN
        COMMIT TRANSACTION;
        EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
        RETURN;
    END;

    -- Failure: keep the evidence, undo everything else.
    IF XACT_STATE() = 1
    BEGIN
        INSERT INTO @log SELECT step_name, started_at, ended_at, rows_read, rows_written, status, error_message
                         FROM etl.load_log WHERE batch_id = @batch_id;
        INSERT INTO @dq  SELECT check_name, severity, measured_value, expected_value, status, details, checked_at
                         FROM etl.dq_result WHERE batch_id = @batch_id;
    END;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

    INSERT INTO etl.load_log (batch_id, step_name, started_at, ended_at, rows_read, rows_written, status, error_message)
    SELECT @batch_id, step_name, started_at, ended_at, rows_read, rows_written, status, error_message FROM @log;
    INSERT INTO etl.dq_result (batch_id, check_name, severity, measured_value, expected_value, status, details, checked_at)
    SELECT @batch_id, check_name, severity, measured_value, expected_value, status, details, checked_at FROM @dq;
    INSERT INTO etl.load_log (batch_id, step_name, started_at, ended_at, status, error_message)
    VALUES (@batch_id, 'pipeline: rolled back', SYSDATETIME(), SYSDATETIME(), 'Failed', @message);

    EXEC etl.end_batch @batch_id = @batch_id, @status = 'Failed';

    THROW 50005, @message, 1;
END;
GO
