/*
  test_dim_finance.sql
  Tests for the four finance dimensions: sql/02_warehouse/19_dim_scenario.sql,
  20_dim_finance_department_group.sql, 21_dim_organization.sql and 22_dim_account.sql.
  Needs staging and dw.dim_territory loaded (dim_organization maps its units to territories).
  Loads the dimensions in one real batch, checks them, proves the soft delete,
  the hierarchy and map guards and the unmapped-unit behaviour inside rolled-back
  transactions, and re-runs to prove nothing changes. Expected results are
  written above each check; the expected values for the organization units and
  the accounts were worked out by hand from the source data, not copied from the load.
*/

USE EnterpriseBI_DW;
GO

-- Precondition: staging must be loaded, or every check below is meaningless
-- (an empty staging makes the loads mark all rows as no longer in the source).
-- NOEXEC ON skips every later batch; it is switched off again at the end of the script.
IF NOT EXISTS (SELECT 1 FROM stg.awdw_dim_scenario)
   OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_department_group)
   OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_organization)
   OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_currency)
   OR NOT EXISTS (SELECT 1 FROM stg.awdw_dim_account)
   OR NOT EXISTS (SELECT 1 FROM stg.aw_sales_territory)
BEGIN
    RAISERROR('Staging is empty. Run etl.load_staging first; tests stopped.', 16, 1);
    SET NOEXEC ON;
END;
GO

-- 0. Load the dimensions in one real batch (dim_territory first: the organization map needs it).
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_territory @batch_id = @batch_id;
EXEC etl.load_dim_scenario @batch_id = @batch_id;
EXEC etl.load_dim_finance_department_group @batch_id = @batch_id;
EXEC etl.load_dim_organization @batch_id = @batch_id;
EXEC etl.load_dim_account @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';
GO

-- 1. Row counts: source rows plus special rows.
--    Expected: 4 rows, all PASS (scenario 3 + 1 = 4, department group 7 + 1 = 8, organization 14 + 1 = 15,
--    account 99 + 1 = 100).
WITH c AS (
SELECT 'dw.dim_scenario' AS dimension, (SELECT COUNT(*) FROM stg.awdw_dim_scenario) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_scenario) AS dimension_rows
UNION ALL
SELECT 'dw.dim_finance_department_group' AS dimension, (SELECT COUNT(*) FROM stg.awdw_dim_department_group) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_finance_department_group) AS dimension_rows
UNION ALL
SELECT 'dw.dim_organization' AS dimension, (SELECT COUNT(*) FROM stg.awdw_dim_organization) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_organization) AS dimension_rows
UNION ALL
SELECT 'dw.dim_account' AS dimension, (SELECT COUNT(*) FROM stg.awdw_dim_account) AS source_rows, 1 AS special_rows, (SELECT COUNT(*) FROM dw.dim_account) AS dimension_rows
)
SELECT  dimension, source_rows, special_rows, dimension_rows,
        CASE WHEN source_rows + special_rows = dimension_rows THEN 'PASS' ELSE 'FAIL' END AS result
FROM c;
GO

-- 2. Business keys unique. Expected: 4 rows, duplicates = 0.
WITH k (dimension, duplicates) AS (
SELECT 'dw.dim_scenario', (SELECT COUNT(*) - COUNT(DISTINCT scenario_id) FROM dw.dim_scenario WHERE scenario_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_finance_department_group', (SELECT COUNT(*) - COUNT(DISTINCT department_group_id) FROM dw.dim_finance_department_group WHERE department_group_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_organization', (SELECT COUNT(*) - COUNT(DISTINCT organization_id) FROM dw.dim_organization WHERE organization_id IS NOT NULL)
UNION ALL
SELECT 'dw.dim_account', (SELECT COUNT(*) - COUNT(DISTINCT account_id) FROM dw.dim_account WHERE account_id IS NOT NULL)
)
SELECT dimension, duplicates, CASE WHEN duplicates = 0 THEN 'PASS' ELSE 'FAIL' END AS result FROM k;
GO

-- 3. Special rows present with their fixed keys. Expected: 4 rows, all PASS.
WITH s (dimension, special_key, expected_row_type, actual_row_type) AS (
SELECT 'dw.dim_scenario', -1, 'Unknown', (SELECT row_type FROM dw.dim_scenario WHERE scenario_key = -1)
UNION ALL
SELECT 'dw.dim_finance_department_group', -1, 'Unknown', (SELECT row_type FROM dw.dim_finance_department_group WHERE finance_department_group_key = -1)
UNION ALL
SELECT 'dw.dim_organization', -1, 'Unknown', (SELECT row_type FROM dw.dim_organization WHERE organization_key = -1)
UNION ALL
SELECT 'dw.dim_account', -1, 'Unknown', (SELECT row_type FROM dw.dim_account WHERE account_key = -1)
)
SELECT  dimension, special_key, expected_row_type, actual_row_type,
        CASE WHEN actual_row_type = expected_row_type THEN 'PASS' ELSE 'FAIL' END AS result
FROM s;
GO

-- 4. Rules. Expected: 91 rows, every row PASS.
--    The 'Unit:' rows check, for each of the 14 organization units, its three levels,
--    region group, currency, leaf or parent, and mapped territory in one line.
--    The 'Account' rows do the same for 16 accounts (levels, statement, code, operator, type,
--    value type, sign, leaf or parent); the profit-line rows reproduce the leaf counts and
--    signs recorded in the design checks (net sales 4, gross margin 6, operating profit 29,
--    net income 35 leaves).
WITH r (rule_checked, expected_value, actual_value) AS (
    SELECT 'Scenario 1 name',                                   'Actual',
           (SELECT scenario_name FROM dw.dim_scenario WHERE scenario_id = 1)
    UNION ALL
    SELECT 'Scenario 2 name',                                   'Budget',
           (SELECT scenario_name FROM dw.dim_scenario WHERE scenario_id = 2)
    UNION ALL
    SELECT 'Scenario 3 name',                                   'Forecast',
           (SELECT scenario_name FROM dw.dim_scenario WHERE scenario_id = 3)
    UNION ALL
    SELECT 'Scenario rows currently in the source',             '3',
           CAST((SELECT COUNT(*) FROM dw.dim_scenario WHERE row_type = 'Source' AND is_in_source = 1) AS varchar(20))
    UNION ALL
    SELECT 'Scenario names that differ from staging',           '0',
           CAST((SELECT COUNT(*) FROM dw.dim_scenario d
                 JOIN stg.awdw_dim_scenario s ON s.ScenarioKey = d.scenario_id
                 WHERE d.scenario_name <> s.ScenarioName) AS varchar(20))
    UNION ALL
    SELECT 'Scenarios named N/A (missing name)',                '0',
           CAST((SELECT COUNT(*) FROM dw.dim_scenario WHERE scenario_name = N'N/A') AS varchar(20))
    UNION ALL
    SELECT 'Name of the special scenario row',                  'Unknown',
           (SELECT scenario_name FROM dw.dim_scenario WHERE scenario_key = -1)
    UNION ALL
    SELECT 'Department group rows with level 1 = Corporate',    '7',
           CAST((SELECT COUNT(*) FROM dw.dim_finance_department_group WHERE row_type = 'Source' AND level_1 = N'Corporate') AS varchar(20))
    UNION ALL
    SELECT 'Rows shown as Corporate (direct)',                  '1',
           CAST((SELECT COUNT(*) FROM dw.dim_finance_department_group WHERE level_2 = N'Corporate (direct)') AS varchar(20))
    UNION ALL
    SELECT 'Rows with is_corporate_direct = 1',                 '1',
           CAST((SELECT COUNT(*) FROM dw.dim_finance_department_group WHERE is_corporate_direct = 1) AS varchar(20))
    UNION ALL
    SELECT 'Business key of Corporate (direct)',                '1',
           CAST((SELECT department_group_id FROM dw.dim_finance_department_group WHERE level_2 = N'Corporate (direct)') AS varchar(20))
    UNION ALL
    SELECT 'Child groups (not direct)',                         '6',
           CAST((SELECT COUNT(*) FROM dw.dim_finance_department_group WHERE row_type = 'Source' AND is_corporate_direct = 0) AS varchar(20))
    UNION ALL
    SELECT 'Child group names that differ from staging',        '0',
           CAST((SELECT COUNT(*) FROM dw.dim_finance_department_group d
                 JOIN stg.awdw_dim_department_group s ON s.DepartmentGroupKey = d.department_group_id
                 WHERE d.is_corporate_direct = 0 AND d.level_2 <> s.DepartmentGroupName) AS varchar(20))
    UNION ALL
    SELECT 'Duplicate level 2 names among source rows',         '0',
           CAST((SELECT COUNT(*) - COUNT(DISTINCT level_2) FROM dw.dim_finance_department_group WHERE row_type = 'Source') AS varchar(20))
    UNION ALL
    SELECT 'Department group rows named N/A',                   '0',
           CAST((SELECT COUNT(*) FROM dw.dim_finance_department_group WHERE level_1 = N'N/A' OR level_2 = N'N/A') AS varchar(20))
    UNION ALL
    SELECT 'Level 2 of group 7',                                'Sales and Marketing',
           (SELECT level_2 FROM dw.dim_finance_department_group WHERE department_group_id = 7)
    UNION ALL
    SELECT 'Level 1 of the special department group row',       'Unknown',
           (SELECT level_1 FROM dw.dim_finance_department_group WHERE finance_department_group_key = -1)
    UNION ALL
    SELECT 'Level 2 of the special department group row',       'Unknown',
           (SELECT level_2 FROM dw.dim_finance_department_group WHERE finance_department_group_key = -1)
    UNION ALL
    SELECT 'Organization rows currently in the source',         '14',
           CAST((SELECT COUNT(*) FROM dw.dim_organization WHERE row_type = 'Source' AND is_in_source = 1) AS varchar(20))
    UNION ALL
    SELECT 'Organization names that differ from staging',       '0',
           CAST((SELECT COUNT(*) FROM dw.dim_organization d
                 JOIN stg.awdw_dim_organization s ON s.OrganizationKey = d.organization_id
                 WHERE d.organization_name <> s.OrganizationName) AS varchar(20))
    UNION ALL
    SELECT 'Leaf units',                                        '9',
           CAST((SELECT COUNT(*) FROM dw.dim_organization WHERE is_leaf = 1 AND row_type = 'Source') AS varchar(20))
    UNION ALL
    SELECT 'Leaf units without a mapped territory',             '0',
           CAST((SELECT COUNT(*) FROM dw.dim_organization WHERE is_leaf = 1 AND row_type = 'Source' AND mapped_territory_code = 'N/A') AS varchar(20))
    UNION ALL
    SELECT 'Units with region group N/A',                       '0',
           CAST((SELECT COUNT(*) FROM dw.dim_organization WHERE row_type = 'Source' AND region_group = N'N/A') AS varchar(20))
    UNION ALL
    SELECT 'Units with currency N/A',                           '0',
           CAST((SELECT COUNT(*) FROM dw.dim_organization WHERE row_type = 'Source' AND currency_code = N'N/A') AS varchar(20))
    UNION ALL
    SELECT 'Rows in the territory map',                         '9',
           CAST((SELECT COUNT(*) FROM etl.org_territory_map) AS varchar(20))
    UNION ALL
    SELECT 'Map names that differ from the source unit names',  '0',
           CAST((SELECT COUNT(*) FROM etl.org_territory_map m
                 JOIN stg.awdw_dim_organization s ON s.OrganizationKey = m.organization_id
                 WHERE m.organization_name <> s.OrganizationName) AS varchar(20))
    UNION ALL
    SELECT 'Map rows pointing to a missing territory',          '0',
           CAST((SELECT COUNT(*) FROM etl.org_territory_map m
                 WHERE NOT EXISTS (SELECT 1 FROM dw.dim_territory t WHERE t.territory_code = m.territory_code)) AS varchar(20))
    UNION ALL
    SELECT 'Leaf units whose region differs from their territory', '0',
           CAST((SELECT COUNT(*) FROM dw.dim_organization o
                 JOIN dw.dim_territory t ON t.territory_code = o.mapped_territory_code
                 WHERE o.is_leaf = 1 AND o.region_group <> t.region_group) AS varchar(20))
    UNION ALL
    SELECT 'Sales territories with no finance unit',            'United Kingdom',
           (SELECT STRING_AGG(territory_name, N', ') FROM dw.dim_territory
            WHERE row_type = 'Source' AND is_region_level = 0
              AND territory_code NOT IN (SELECT territory_code FROM etl.org_territory_map))
    UNION ALL
    SELECT 'Region group of the special organization row',      'Unknown',
           (SELECT region_group FROM dw.dim_organization WHERE organization_key = -1)
    UNION ALL
    SELECT 'Currency of the special organization row',          'N/A',
           (SELECT currency_code FROM dw.dim_organization WHERE organization_key = -1)
    UNION ALL
    SELECT 'Unit: AdventureWorks Cycle', N'AdventureWorks Cycle > AdventureWorks Cycle > AdventureWorks Cycle | All regions | USD | parent | N/A',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'AdventureWorks Cycle')
    UNION ALL
    SELECT 'Unit: North America Operations', N'North America Operations > North America Operations > North America Operations | North America | USD | parent | N/A',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'North America Operations')
    UNION ALL
    SELECT 'Unit: Northeast Division', N'North America Operations > USA Operations > Northeast Division | North America | USD | leaf | Northeast',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Northeast Division')
    UNION ALL
    SELECT 'Unit: Northwest Division', N'North America Operations > USA Operations > Northwest Division | North America | USD | leaf | Northwest',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Northwest Division')
    UNION ALL
    SELECT 'Unit: Central Division', N'North America Operations > USA Operations > Central Division | North America | USD | leaf | Central',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Central Division')
    UNION ALL
    SELECT 'Unit: Southeast Division', N'North America Operations > USA Operations > Southeast Division | North America | USD | leaf | Southeast',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Southeast Division')
    UNION ALL
    SELECT 'Unit: Southwest Division', N'North America Operations > USA Operations > Southwest Division | North America | USD | leaf | Southwest',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Southwest Division')
    UNION ALL
    SELECT 'Unit: Canadian Division', N'North America Operations > Canadian Division > Canadian Division | North America | CAD | leaf | Canada',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Canadian Division')
    UNION ALL
    SELECT 'Unit: European Operations', N'European Operations > European Operations > European Operations | Europe | EUR | parent | N/A',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'European Operations')
    UNION ALL
    SELECT 'Unit: Pacific Operations', N'Pacific Operations > Pacific Operations > Pacific Operations | Pacific | AUD | parent | N/A',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Pacific Operations')
    UNION ALL
    SELECT 'Unit: France', N'European Operations > France > France | Europe | EUR | leaf | France',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'France')
    UNION ALL
    SELECT 'Unit: Germany', N'European Operations > Germany > Germany | Europe | EUR | leaf | Germany',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Germany')
    UNION ALL
    SELECT 'Unit: Australia', N'Pacific Operations > Australia > Australia | Pacific | AUD | leaf | Australia',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'Australia')
    UNION ALL
    SELECT 'Unit: USA Operations', N'North America Operations > USA Operations > USA Operations | North America | USD | parent | N/A',
           (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' | ', region_group, N' | ', currency_code, N' | ',
                          CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END, N' | ', mapped_territory_name)
            FROM dw.dim_organization WHERE organization_name = N'USA Operations')
    UNION ALL
    SELECT 'Account rows currently in the source', '99', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND is_in_source = 1) AS varchar(20))
    UNION ALL
    SELECT 'Account names that differ from staging', '0', CAST((SELECT COUNT(*) FROM dw.dim_account d
                 JOIN stg.awdw_dim_account s ON s.AccountKey = d.account_id
                 WHERE d.account_name <> s.AccountDescription) AS varchar(20))
    UNION ALL
    SELECT 'Duplicate account codes among source rows', '0', CAST((SELECT COUNT(*) - COUNT(DISTINCT account_code) FROM dw.dim_account WHERE row_type = 'Source') AS varchar(20))
    UNION ALL
    SELECT 'Leaf accounts', '72', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND is_leaf = 1) AS varchar(20))
    UNION ALL
    SELECT 'Parent accounts', '27', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND is_leaf = 0) AS varchar(20))
    UNION ALL
    SELECT 'Accounts in statement: Balance sheet', '46', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND statement = 'Balance sheet') AS varchar(20))
    UNION ALL
    SELECT 'Accounts in statement: Income statement', '48', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND statement = 'Income statement') AS varchar(20))
    UNION ALL
    SELECT 'Accounts in statement: Statistical', '5', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND statement = 'Statistical') AS varchar(20))
    UNION ALL
    SELECT 'Accounts with statement N/A', '0', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND statement = 'N/A') AS varchar(20))
    UNION ALL
    SELECT 'Accounts with sign +1 (adds to net income)', '12', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND sign_to_net_income = 1) AS varchar(20))
    UNION ALL
    SELECT 'Accounts with sign -1 (subtracts from net income)', '36', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND sign_to_net_income = -1) AS varchar(20))
    UNION ALL
    SELECT 'Accounts with sign 0 (not part of net income)', '51', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND sign_to_net_income = 0) AS varchar(20))
    UNION ALL
    SELECT 'Balance sheet or Statistical accounts with a sign other than 0', '0', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE statement IN ('Balance sheet', 'Statistical') AND sign_to_net_income <> 0) AS varchar(20))
    UNION ALL
    SELECT 'Net Sales: leaves / added / subtracted', '4 / 2 / 2', (SELECT CONCAT(COUNT(*), ' / ', SUM(CASE WHEN sign_to_net_income = 1 THEN 1 ELSE 0 END), ' / ', SUM(CASE WHEN sign_to_net_income = -1 THEN 1 ELSE 0 END))
            FROM dw.dim_account WHERE is_leaf = 1 AND statement = 'Income statement' AND level_4 = N'Net Sales')
    UNION ALL
    SELECT 'Gross Margin: leaves / added / subtracted', '6 / 2 / 4', (SELECT CONCAT(COUNT(*), ' / ', SUM(CASE WHEN sign_to_net_income = 1 THEN 1 ELSE 0 END), ' / ', SUM(CASE WHEN sign_to_net_income = -1 THEN 1 ELSE 0 END))
            FROM dw.dim_account WHERE is_leaf = 1 AND statement = 'Income statement' AND level_3 = N'Gross Margin')
    UNION ALL
    SELECT 'Operating Profit: leaves / added / subtracted', '29 / 2 / 27', (SELECT CONCAT(COUNT(*), ' / ', SUM(CASE WHEN sign_to_net_income = 1 THEN 1 ELSE 0 END), ' / ', SUM(CASE WHEN sign_to_net_income = -1 THEN 1 ELSE 0 END))
            FROM dw.dim_account WHERE is_leaf = 1 AND statement = 'Income statement' AND level_2 = N'Operating Profit')
    UNION ALL
    SELECT 'Net Income: leaves / added / subtracted', '35 / 6 / 29', (SELECT CONCAT(COUNT(*), ' / ', SUM(CASE WHEN sign_to_net_income = 1 THEN 1 ELSE 0 END), ' / ', SUM(CASE WHEN sign_to_net_income = -1 THEN 1 ELSE 0 END))
            FROM dw.dim_account WHERE is_leaf = 1 AND statement = 'Income statement' AND level_1 = N'Net Income')
    UNION ALL
    SELECT 'Accounts at the sixth level (level 5 differs from level 6)', '5', CAST((SELECT COUNT(*) FROM dw.dim_account WHERE row_type = 'Source' AND level_5 <> level_6) AS varchar(20))
    UNION ALL
    SELECT 'Sort order: distinct / lowest / highest', '99 / 1 / 99', (SELECT CONCAT(COUNT(DISTINCT sort_order), ' / ', MIN(sort_order), ' / ', MAX(sort_order))
            FROM dw.dim_account WHERE row_type = 'Source')
    UNION ALL
    SELECT 'Sort order of account 1 (Balance Sheet)', '1', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 1) AS varchar(20))
    UNION ALL
    SELECT 'Sort order of account 47 (Net Income)', '47', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 47) AS varchar(20))
    UNION ALL
    SELECT 'Sort order of account 95 (Statistical Accounts)', '95', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 95) AS varchar(20))
    UNION ALL
    SELECT 'Sort order of account 63 (Commissions)', '64', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 63) AS varchar(20))
    UNION ALL
    SELECT 'Sort order of account 64 (Travel Expenses)', '65', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 64) AS varchar(20))
    UNION ALL
    SELECT 'Sort order of account 100 (Current Installments of Long-term Debt)', '28', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 100) AS varchar(20))
    UNION ALL
    SELECT 'Sort order of account 101 (Trade Sales)', '52', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 101) AS varchar(20))
    UNION ALL
    SELECT 'Sort order of account 52 (Intercompany Sales)', '53', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 52) AS varchar(20))
    UNION ALL
    SELECT 'Sort order of account 99 (Square Footage)', '99', CAST((SELECT sort_order FROM dw.dim_account WHERE account_id = 99) AS varchar(20))
    UNION ALL
    SELECT 'Account 1: Balance Sheet', N'Balance Sheet > Balance Sheet > Balance Sheet > Balance Sheet > Balance Sheet > Balance Sheet | Balance sheet | 1 | ~ | N/A | Currency | 0 | parent', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 1)
    UNION ALL
    SELECT 'Account 4: Cash', N'Balance Sheet > Assets > Current Assets > Cash > Cash > Cash | Balance sheet | 1110 | + | Assets | Currency | 0 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 4)
    UNION ALL
    SELECT 'Account 31: Salary & Other Comp', N'Balance Sheet > Liabilities and Owners Equity > Liabilities > Current Liabilities > Accrued Expenses > Salary & Other Comp | Balance sheet | 2310 | + | Liabilities | Currency | 0 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 31)
    UNION ALL
    SELECT 'Account 47: Net Income', N'Net Income > Net Income > Net Income > Net Income > Net Income > Net Income | Income statement | 4 | + | Revenue | Currency | 1 | parent', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 47)
    UNION ALL
    SELECT 'Account 50: Net Sales', N'Net Income > Operating Profit > Gross Margin > Net Sales > Net Sales > Net Sales | Income statement | 4100 | + | Revenue | Currency | 1 | parent', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 50)
    UNION ALL
    SELECT 'Account 53: Returns and Adjustments', N'Net Income > Operating Profit > Gross Margin > Net Sales > Returns and Adjustments > Returns and Adjustments | Income statement | 4130 | - | Expenditures | Currency | -1 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 53)
    UNION ALL
    SELECT 'Account 56: Standard Cost of Sales', N'Net Income > Operating Profit > Gross Margin > Total Cost of Sales > Standard Cost of Sales > Standard Cost of Sales | Income statement | 5020 | + | Expenditures | Currency | -1 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 56)
    UNION ALL
    SELECT 'Account 63: Commissions', N'Net Income > Operating Profit > Operating Expenses > Commissions > Commissions > Commissions | Income statement | 6100 | + | Expenditures | Currency | -1 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 63)
    UNION ALL
    SELECT 'Account 87: Rent', N'Net Income > Operating Profit > Operating Expenses > Rent > Rent > Rent | Income statement | 6920 | + | Expenditures | Currency | -1 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 87)
    UNION ALL
    SELECT 'Account 90: Interest Expense', N'Net Income > Other Income and Expense > Interest Expense > Interest Expense > Interest Expense > Interest Expense | Income statement | 8010 | - | Expenditures | Currency | -1 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 90)
    UNION ALL
    SELECT 'Account 94: Taxes', N'Net Income > Taxes > Taxes > Taxes > Taxes > Taxes | Income statement | 8500 | - | Expenditures | Currency | -1 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 94)
    UNION ALL
    SELECT 'Account 95: Statistical Accounts', N'Statistical Accounts > Statistical Accounts > Statistical Accounts > Statistical Accounts > Statistical Accounts > Statistical Accounts | Statistical | 9500 | ~ | Statistical | Units | 0 | parent', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 95)
    UNION ALL
    SELECT 'Account 96: Headcount', N'Statistical Accounts > Headcount > Headcount > Headcount > Headcount > Headcount | Statistical | 9510 | ~ | Balances | Units | 0 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 96)
    UNION ALL
    SELECT 'Account 98: Average Unit Price', N'Statistical Accounts > Average Unit Price > Average Unit Price > Average Unit Price > Average Unit Price > Average Unit Price | Statistical | 9530 | ~ | Balances | Currency | 0 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 98)
    UNION ALL
    SELECT 'Account 100: Current Installments of Long-term Debt', N'Balance Sheet > Liabilities and Owners Equity > Liabilities > Current Liabilities > Current Installments of Long-term Debt > Current Installments of Long-term Debt | Balance sheet | 2220 | + | Liabilities | Currency | 0 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 100)
    UNION ALL
    SELECT 'Account 101: Trade Sales', N'Net Income > Operating Profit > Gross Margin > Net Sales > Gross Sales > Trade Sales | Income statement | 4200 | + | Revenue | Currency | 1 | leaf', (SELECT CONCAT(level_1, N' > ', level_2, N' > ', level_3, N' > ', level_4, N' > ', level_5, N' > ', level_6,
                          N' | ', statement, N' | ', account_code, N' | ', [operator], N' | ', account_type, N' | ', value_type,
                          N' | ', sign_to_net_income, N' | ', CASE is_leaf WHEN 1 THEN 'leaf' ELSE 'parent' END)
            FROM dw.dim_account WHERE account_id = 101)
    UNION ALL
    SELECT 'Statement of the special account row', 'Unknown', (SELECT statement FROM dw.dim_account WHERE account_key = -1)
    UNION ALL
    SELECT 'Sign of the special account row', '0', CAST((SELECT sign_to_net_income FROM dw.dim_account WHERE account_key = -1) AS varchar(20))
)
SELECT  rule_checked, expected_value, actual_value,
        CASE WHEN actual_value = expected_value THEN 'PASS' ELSE 'FAIL' END AS result
FROM r;
GO

-- 5. Lineage. Expected: 4 rows, rows_without_lineage = 0.
WITH l (dimension, rows_without_lineage) AS (
SELECT 'dw.dim_scenario', (SELECT COUNT(*) FROM dw.dim_scenario WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_finance_department_group', (SELECT COUNT(*) FROM dw.dim_finance_department_group WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_organization', (SELECT COUNT(*) FROM dw.dim_organization WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
UNION ALL
SELECT 'dw.dim_account', (SELECT COUNT(*) FROM dw.dim_account WHERE inserted_batch_id IS NULL OR updated_batch_id IS NULL)
)
SELECT dimension, rows_without_lineage FROM l;
GO

-- 6a. Soft delete, inside a transaction that is rolled back:
--     remove the Forecast scenario (id 3) from staging, reload the dimension.
--     Expected: inside: rows_total 4, is_in_source_scenario_3 = 0, rows_written 1;
--     after rollback: rows_total 4, is_in_source_scenario_3 = 1.
BEGIN TRANSACTION;

DELETE FROM stg.awdw_dim_scenario WHERE ScenarioKey = 3;

DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_scenario @batch_id = @batch_id;

SELECT  'inside transaction' AS moment,
        (SELECT COUNT(*) FROM dw.dim_scenario)                                      AS rows_total,
        (SELECT is_in_source FROM dw.dim_scenario WHERE scenario_id = 3)            AS is_in_source_scenario_3,
        (SELECT rows_written FROM etl.load_log WHERE batch_id = @batch_id)          AS rows_written;

ROLLBACK TRANSACTION;

SELECT  'after rollback' AS moment,
        (SELECT COUNT(*) FROM dw.dim_scenario)                                      AS rows_total,
        (SELECT is_in_source FROM dw.dim_scenario WHERE scenario_id = 3)            AS is_in_source_scenario_3,
        NULL                                                                        AS rows_written;
GO

-- 6b. Soft delete for the department group, same method:
--     remove group 7 (Sales and Marketing) from staging, reload the dimension.
--     Expected: inside: rows_total 8, is_in_source_group_7 = 0, rows_written 1;
--     after rollback: rows_total 8, is_in_source_group_7 = 1.
BEGIN TRANSACTION;

DELETE FROM stg.awdw_dim_department_group WHERE DepartmentGroupKey = 7;

DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_finance_department_group @batch_id = @batch_id;

SELECT  'inside transaction' AS moment,
        (SELECT COUNT(*) FROM dw.dim_finance_department_group)                                     AS rows_total,
        (SELECT is_in_source FROM dw.dim_finance_department_group WHERE department_group_id = 7)   AS is_in_source_group_7,
        (SELECT rows_written FROM etl.load_log WHERE batch_id = @batch_id)                         AS rows_written;

ROLLBACK TRANSACTION;

SELECT  'after rollback' AS moment,
        (SELECT COUNT(*) FROM dw.dim_finance_department_group)                                     AS rows_total,
        (SELECT is_in_source FROM dw.dim_finance_department_group WHERE department_group_id = 7)   AS is_in_source_group_7,
        NULL                                                                                       AS rows_written;
GO

-- 6c. Hierarchy guard, inside a transaction that is rolled back:
--     add a third level (a group whose parent is group 2) to staging and load.
--     Expected: 1 row, guard_result = rejected, dimension_rows_after = 8.
BEGIN TRANSACTION;

INSERT INTO stg.awdw_dim_department_group (DepartmentGroupKey, ParentDepartmentGroupKey, DepartmentGroupName, batch_id, loaded_at)
SELECT 99, 2, N'Test third level', MIN(batch_id), SYSDATETIME() FROM stg.awdw_dim_department_group;

DECLARE @batch_id int, @guard_result varchar(30);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRY
    EXEC etl.load_dim_finance_department_group @batch_id = @batch_id;
    SET @guard_result = 'NOT rejected';
END TRY
BEGIN CATCH
    SET @guard_result = CASE WHEN ERROR_MESSAGE() LIKE '%two-level hierarchy%' THEN 'rejected' ELSE 'other error' END;
END CATCH;

SELECT  @guard_result AS guard_result,
        (SELECT COUNT(*) FROM dw.dim_finance_department_group) AS dimension_rows_after;

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO

-- 6d. Soft delete for the organization, same method:
--     remove Germany (unit 12) from staging, reload the dimension.
--     Only Germany changes: its parent still has France, so nothing else is rewritten.
--     Expected: inside: rows_total 15, is_in_source_unit_12 = 0, rows_written 1;
--     after rollback: rows_total 15, is_in_source_unit_12 = 1.
BEGIN TRANSACTION;

DELETE FROM stg.awdw_dim_organization WHERE OrganizationKey = 12;

DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_organization @batch_id = @batch_id;

SELECT  'inside transaction' AS moment,
        (SELECT COUNT(*) FROM dw.dim_organization)                                  AS rows_total,
        (SELECT is_in_source FROM dw.dim_organization WHERE organization_id = 12)   AS is_in_source_unit_12,
        (SELECT rows_written FROM etl.load_log WHERE batch_id = @batch_id)          AS rows_written;

ROLLBACK TRANSACTION;

SELECT  'after rollback' AS moment,
        (SELECT COUNT(*) FROM dw.dim_organization)                                  AS rows_total,
        (SELECT is_in_source FROM dw.dim_organization WHERE organization_id = 12)   AS is_in_source_unit_12,
        NULL                                                                        AS rows_written;
GO

-- 6e. Hierarchy guard for the organization, inside a transaction that is rolled back:
--     add a unit below Northeast Division (a fifth level) to staging and load.
--     Expected: 1 row, guard_result = rejected, dimension_rows_after = 15.
BEGIN TRANSACTION;

INSERT INTO stg.awdw_dim_organization (OrganizationKey, ParentOrganizationKey, OrganizationName, CurrencyKey, batch_id, loaded_at)
SELECT 99, 3, N'Test fifth level', MIN(CurrencyKey), MIN(batch_id), SYSDATETIME() FROM stg.awdw_dim_organization;

DECLARE @batch_id int, @guard_result varchar(30);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRY
    EXEC etl.load_dim_organization @batch_id = @batch_id;
    SET @guard_result = 'NOT rejected';
END TRY
BEGIN CATCH
    SET @guard_result = CASE WHEN ERROR_MESSAGE() LIKE '%at most four levels%' THEN 'rejected' ELSE 'other error' END;
END CATCH;

SELECT  @guard_result AS guard_result,
        (SELECT COUNT(*) FROM dw.dim_organization) AS dimension_rows_after;

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO

-- 6f. Map guard, inside a transaction that is rolled back:
--     add a map row pointing to a territory that does not exist, and load.
--     Expected: 1 row, guard_result = rejected, dimension_rows_after = 15.
BEGIN TRANSACTION;

INSERT INTO etl.org_territory_map (organization_id, organization_name, territory_code)
VALUES (99, N'Test map row', 'NO-SUCH-TERRITORY');

DECLARE @batch_id int, @guard_result varchar(30);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRY
    EXEC etl.load_dim_organization @batch_id = @batch_id;
    SET @guard_result = 'NOT rejected';
END TRY
BEGIN CATCH
    SET @guard_result = CASE WHEN ERROR_MESSAGE() LIKE '%org_territory_map points to a territory%' THEN 'rejected' ELSE 'other error' END;
END CATCH;

SELECT  @guard_result AS guard_result,
        (SELECT COUNT(*) FROM dw.dim_organization) AS dimension_rows_after;

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO

-- 6g. A new leaf unit that is not in the map, inside a transaction that is rolled back:
--     add a unit below USA Operations (unit 14) to staging, without a map row, and load.
--     It must get region group N/A (it matches no regional manager) and must not change
--     the region of its parent. Expected: 1 row, result = PASS.
BEGIN TRANSACTION;

INSERT INTO stg.awdw_dim_organization (OrganizationKey, ParentOrganizationKey, OrganizationName, CurrencyKey, batch_id, loaded_at)
SELECT 99, 14, N'Test unmapped unit', MIN(CurrencyKey), MIN(batch_id), SYSDATETIME() FROM stg.awdw_dim_organization;

DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_organization @batch_id = @batch_id;

SELECT  (SELECT region_group FROM dw.dim_organization WHERE organization_id = 99)           AS new_unit_region_group,
        (SELECT mapped_territory_code FROM dw.dim_organization WHERE organization_id = 99)  AS new_unit_territory_code,
        (SELECT is_leaf FROM dw.dim_organization WHERE organization_id = 99)                AS new_unit_is_leaf,
        (SELECT region_group FROM dw.dim_organization WHERE organization_id = 14)           AS usa_operations_region_group,
        CASE WHEN (SELECT region_group FROM dw.dim_organization WHERE organization_id = 99) = N'N/A'
              AND (SELECT mapped_territory_code FROM dw.dim_organization WHERE organization_id = 99) = 'N/A'
              AND (SELECT is_leaf FROM dw.dim_organization WHERE organization_id = 99) = 1
              AND (SELECT region_group FROM dw.dim_organization WHERE organization_id = 14) = N'North America'
             THEN 'PASS' ELSE 'FAIL' END                                                     AS result;

ROLLBACK TRANSACTION;
GO

-- 6h. Soft delete for the account, same method:
--     remove account 99 (Square Footage, the last account in sort order) from staging, reload.
--     It is last, so no other account's sort order moves and only that row is written.
--     Expected: inside: rows_total 100, is_in_source_account_99 = 0, rows_written 1;
--     after rollback: rows_total 100, is_in_source_account_99 = 1.
BEGIN TRANSACTION;

DELETE FROM stg.awdw_dim_account WHERE AccountKey = 99;

DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_account @batch_id = @batch_id;

SELECT  'inside transaction' AS moment,
        (SELECT COUNT(*) FROM dw.dim_account)                                       AS rows_total,
        (SELECT is_in_source FROM dw.dim_account WHERE account_id = 99)             AS is_in_source_account_99,
        (SELECT rows_written FROM etl.load_log WHERE batch_id = @batch_id)          AS rows_written;

ROLLBACK TRANSACTION;

SELECT  'after rollback' AS moment,
        (SELECT COUNT(*) FROM dw.dim_account)                                       AS rows_total,
        (SELECT is_in_source FROM dw.dim_account WHERE account_id = 99)             AS is_in_source_account_99,
        NULL                                                                        AS rows_written;
GO

-- 6i. Level guard for the account, inside a transaction that is rolled back:
--     add an account below Salary & Other Comp (account 31, already at the sixth level) and load.
--     Expected: 1 row, guard_result = rejected, dimension_rows_after = 100.
BEGIN TRANSACTION;

INSERT INTO stg.awdw_dim_account (AccountKey, ParentAccountKey, AccountCodeAlternateKey, AccountDescription, AccountType, [Operator], ValueType, batch_id, loaded_at)
SELECT 9999, 31, 99999, N'Test seventh level', N'Liabilities', N'+', N'Currency', MIN(batch_id), SYSDATETIME() FROM stg.awdw_dim_account;

DECLARE @batch_id int, @guard_result varchar(30);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRY
    EXEC etl.load_dim_account @batch_id = @batch_id;
    SET @guard_result = 'NOT rejected';
END TRY
BEGIN CATCH
    SET @guard_result = CASE WHEN ERROR_MESSAGE() LIKE '%at most six levels%' THEN 'rejected' ELSE 'other error' END;
END CATCH;

SELECT  @guard_result AS guard_result,
        (SELECT COUNT(*) FROM dw.dim_account) AS dimension_rows_after;

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO

-- 6j. Statement guard for the account, inside a transaction that is rolled back:
--     add a new top account whose code is not one of the three known statements and load.
--     Expected: 1 row, guard_result = rejected, dimension_rows_after = 100.
BEGIN TRANSACTION;

INSERT INTO stg.awdw_dim_account (AccountKey, ParentAccountKey, AccountCodeAlternateKey, AccountDescription, AccountType, [Operator], ValueType, batch_id, loaded_at)
SELECT 9998, NULL, 98765, N'Test statement', N'Test', N'~', N'Currency', MIN(batch_id), SYSDATETIME() FROM stg.awdw_dim_account;

DECLARE @batch_id int, @guard_result varchar(30);
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;

BEGIN TRY
    EXEC etl.load_dim_account @batch_id = @batch_id;
    SET @guard_result = 'NOT rejected';
END TRY
BEGIN CATCH
    SET @guard_result = CASE WHEN ERROR_MESSAGE() LIKE '%not a known statement%' THEN 'rejected' ELSE 'other error' END;
END CATCH;

SELECT  @guard_result AS guard_result,
        (SELECT COUNT(*) FROM dw.dim_account) AS dimension_rows_after;

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
GO

-- 7. Re-run: a second load of all five writes nothing.
--    Expected: 5 steps, all Succeeded, total rows_written = 0.
DECLARE @batch_id int;
EXEC etl.start_batch @batch_id = @batch_id OUTPUT;
EXEC etl.load_dim_territory @batch_id = @batch_id;
EXEC etl.load_dim_scenario @batch_id = @batch_id;
EXEC etl.load_dim_finance_department_group @batch_id = @batch_id;
EXEC etl.load_dim_organization @batch_id = @batch_id;
EXEC etl.load_dim_account @batch_id = @batch_id;
EXEC etl.end_batch @batch_id = @batch_id, @status = 'Succeeded';

SELECT  COUNT(*)                                               AS steps,
        SUM(CASE WHEN status = 'Succeeded' THEN 1 ELSE 0 END)  AS steps_succeeded,
        SUM(rows_written)                                      AS total_rows_written
FROM etl.load_log
WHERE batch_id = @batch_id;
GO


-- Switch execution back on (see the precondition at the top).
SET NOEXEC OFF;
GO