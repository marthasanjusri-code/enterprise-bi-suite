# Decision Log

Every design decision for the Enterprise BI Suite, with the reason and the evidence behind it.
Evidence points to a file in this repository and the check inside it, where the query and its
result are recorded.

`docs/source_inventory.xlsx` records the Step 1 table and column decisions. Where a later decision
in this log changes one of them (for example D49, D53), this log takes precedence.

**Evidence files**

| Short name | File |
|---|---|
| Inventory | `docs/source_inventory.xlsx` |
| Source profiling | `sql/00_source_profiling/01_source_profiling.sql` |
| Value profiling | `sql/00_source_profiling/02_value_profiling.sql` |
| Sales checks | `sql/01_design_checks/fact_sales_checks.sql` |
| Quota checks | `sql/01_design_checks/fact_sales_quota_checks.sql` |
| Finance checks | `sql/01_design_checks/fact_finance_checks.sql` |
| Purchase checks | `sql/01_design_checks/fact_purchase_checks.sql` |
| Work order checks | `sql/01_design_checks/fact_work_order_checks.sql` |
| Inventory current checks | `sql/01_design_checks/fact_inventory_current_checks.sql` |
| Inventory daily checks | `sql/01_design_checks/fact_inventory_daily_checks.sql` |
| Headcount checks | `sql/01_design_checks/fact_headcount_monthly_checks.sql` |
| Date checks | `sql/01_design_checks/dim_date_checks.sql` |
| Product checks | `sql/01_design_checks/dim_product_checks.sql` |
| Territory checks | `sql/01_design_checks/dim_territory_checks.sql` |
| Employee checks | `sql/01_design_checks/dim_employee_checks.sql` |
| Customer checks | `sql/01_design_checks/dim_customer_checks.sql` |
| Reference checks | `sql/01_design_checks/dim_reference_checks.sql` |
| Finance dimension checks | `sql/01_design_checks/dim_finance_checks.sql` |

---

## 1. Sources and scope

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D01 | Use AdventureWorks2025 as the operations source (sales, HR, purchasing, production) and AdventureWorksDW2025 as the finance source. | The 2025 versions match SQL Server 2025. Finance data exists only in the DW database. | Source profiling: table row counts |
| D02 | Select tables with four tests: module fit, business value, duplication, privacy. Result: 38 used, 8 optional, 14 reference, 42 excluded, out of 102. | A model built only from what the business questions need. | Inventory: Table Decisions |
| D03 | Exclude personal and payment data: passwords, email addresses, phone numbers, credit cards, national ID, login, marital status, street addresses. | Not needed for any business question; privacy by design. | Inventory: Column Decisions |
| D04 | Use base tables, not the sample views or the helper functions shipped with AdventureWorks. | Full control over every join and column. | Inventory |
| D05 | Code meanings (status, product line, class, style, pay frequency, credit rating, channel) are taken from the source's own column descriptions and functions. | The source is the authority, not memory or guesswork. | Value profiling: official meaning of code columns, status codes |
| D06 | TransactionHistoryArchive is older history (2022-04 to 2024-07), not a duplicate. Kept as optional. | Date and ID ranges do not overlap; 0 shared IDs. | Source profiling: archive duplicate check |
| D101 | The Step 1 inventory is reconciled with the built warehouse: 2 tables promoted (ProductVendor for promised lead time, FactCurrencyRate for D36), 4 tables dropped (Address and StateProvince by D93; DW FactProductInventory and DimProduct by D49), and the column decisions brought in line with staging. The Step 1 decision is kept as history; new columns "Final decision", "Changed by" and "Change reason" record every change. | The inventory listed columns that were never loaded and missed columns that are. After reconciliation, 36 tables and 195 columns are "Use" or "Use (pipeline)": exactly the tables and source columns in staging. | Inventory: Final decision columns; `sql/02_warehouse/03_staging_tables.sql` |

## 2. Architecture and tools

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D07 | One warehouse database `EnterpriseBI_DW` with schemas `stg` (raw copies), `dw` (star schema), `etl` (load log). | Separates the layers while keeping one connection, one backup and simple queries. | Design discussion, Step 2.1 |
| D08 | Heavy logic in SQL stored procedures; light shaping in Power Query (friendly names, data types, hiding technical columns). | SQL logic is scheduled, testable and reusable; Power Query use is shown deliberately as the brief asks. | Step 2.1 |
| D09 | Pipeline: SQL Server Agent job calling stored procedures. An Azure Data Factory pipeline calling the same procedures is optional. | Agent is free and already running; logic written once, any scheduler can call it. | Step 2.1 |
| D10 | Every fact gets `batch_id` and `loaded_at`, linked to `etl.load_log`. | Every row can be traced to the load that produced it. | Step 2.4 |
| D11 | Step 7 is completed in Power BI Desktop with a recorded demo; Power BI Service is not used. | Confirmed by the Nexvia Technical Team: Service is not mandatory. | Email reply, November 2026 |
| D12 | Naming: `stg.<source_table>`, `dw.dim_<name>`, `dw.fact_<name>`, `<name>_key` (surrogate), `<name>_id` (business key), snake_case. | Consistent, readable names. | Step 2.1 |

## 3. Business questions and KPI definitions

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D13 | The model is designed from business questions S1-S9, F1-F8, H1-H5, P1-P9 and an executive overview. | Tables exist only to answer questions. | `business_questions.md` (Step 2.2) |
| D14 | Revenue = sum of line totals (after discount, before tax and freight), excluding Rejected and Cancelled orders. | Standard revenue definition; tax and freight are not sales income. Line totals add up to every order's SubTotal. | Sales checks: checks 2 and 3 |
| D15 | HR "top performing employees" is not built. | The source has no performance data for non-sales roles; pay or tenure as a proxy would be misleading and unfair. | `business_questions.md` (Step 2.2) |
| D16 | "Top performing salespeople" (S9) is built from revenue and quota attainment. | Salesperson performance is measurable in the data. | `business_questions.md`, S9 (Step 2.2) |
| D17 | Measures use NULL for unknown values; keys never use NULL. | Aggregates skip NULL, so averages stay correct and coverage can be counted. A NULL key would make rows disappear from visuals. | Work order checks: cost decisions |
| D18 | A KPI that never varies is kept as a hidden measure, not shown: sales on-time shipping (always 7-8 days), vendor on-time delivery (100%). | A constant KPI gives no information; keeping the data allows it to be shown if data changes. | Sales checks: check 6; Purchase checks: check G |
| D107 | The business questions are kept in `business_questions.md`: 24 taken from saved screenshots of the Step 2.2 list (S2, S4, F2, H3 improved on 10 Nov 2026 with evidence; P1, P3, P7 shown as changed by D42, D43, D47, originals quoted); S9, F5-F8, P8, P9 and the executive overview rebuilt on 10 Nov 2026 from what the repository already fixes for them, and confirmed by the project owner. The documents of Steps 2.1, 2.4, 2.6 and 2.7 were not kept; their outcomes are the decisions in this log that cite them. | The original Step 2.2 document was not kept. Rebuilding only from recorded evidence keeps every question consistent with the built design; every change quotes the original wording and gives its evidence. | `business_questions.md` |

## 4. Dates and timelines

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D19 | OLTP sales, purchasing and production dates are used as they are (2022-2025). | Already on the 2025 timeline. | Value profiling: timeline audit |
| D20 | DW dates (finance) are shifted +4,170 days. | All 121,253 matched order lines between DW and OLTP show exactly this offset. | Value profiling: date offset between DW and OLTP |
| D21 | All HR dates, including birth dates, are shifted +4,017 days. | DW-to-HR offset is 153 days, so 4,170 - 153. 16 of 17 salespeople are hired on or before their first territory, quota and order after the shift (11 on the exact day). Shifting birth dates too gives realistic ages (18-60 at hire). | Value profiling: HR shift tests |
| D22 | `dim_date` covers whole years 2017-01-01 to 2025-12-31, with no "unknown" row. | Covers every fact and hire date; whole years for time intelligence; Power BI needs a gap-free, unique date table. Missing dates are caught by a data quality check (none today). | Date checks |
| D23 | Fiscal year starts 1 July, named by the year it ends (FY2025 = Jul 2024 - Jun 2025). Calendar year is the default; fiscal YTD on finance pages. | The DW calendar shows Q1 = July-September; its fiscal year numbers are inconsistent, so they are derived, not copied. | Date checks: check 2 |
| D24 | YTD and "latest" measures use each module's own last data date, never today and never one shared date. Each KPI shows its "as of" date. | Modules end on different dates (finance May 2025, sales June 2025, purchases October 2025). | Date checks: check 1 |

## 5. Fact tables

### fact_sales (one row per sales order line)

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D25 | Grain: one row per order line (121,317 lines). | Lowest useful level; line IDs are unique. | Sales checks: check 1 |
| D26 | Unit cost = latest cost period started on or before the order date. 64 lines on 25 products sold after their cost history ended get the last known cost, flagged `is_cost_estimated`. | Cost periods are back to back with inclusive end dates; the latest period equals the product's current standard cost. | Sales checks: checks 4, 5 and the cost rule test |
| D27 | The 64 lines are kept. | They are real sales. Microsoft's DW dropped exactly these 64 lines (23 orders), which explains the DW-vs-OLTP line gap. | Sales checks: the 64 order lines with no cost period |
| D28 | `order_status` is kept, and the revenue rule excludes Rejected and Cancelled orders. | Every order is Shipped today, but the source allows other statuses (defensive design). | Value profiling: status codes |
| D29 | Due and ship date keys are kept; shipping KPIs are DAX measures, hidden. | Cheap to keep, expensive to add later. | Sales checks: check 6 |
| D102 | `ship_date_key` may be empty; `order_date_key` and `due_date_key` may not. | The source allows an empty ShipDate (an order not yet shipped) but not an empty OrderDate or DueDate. `dim_date` has no unknown row (D22), so an empty key is the only way to load an unshipped order without stopping the load. 0 lines have no ship date today. | Inventory: Nullable column of SalesOrderHeader; `tests/test_fact_sales.sql` test 2 |
| D104 | `order_status` holds the text the source function `dbo.ufnGetSalesOrderStatusText` returns: 1 In process, 2 Approved, 3 Backordered, 4 Rejected, 5 Shipped, 6 Cancelled, any other code "** Invalid **". | D05: the source is the authority. The function definition was read from the source on 10 Nov 2026, and a test compares every loaded line with the function. | Sales checks: status text function; `tests/test_fact_sales.sql` test 3 |
| D105 | Money amounts in `fact_sales` keep the source's 6 decimals (`decimal(19,6)`). | Revenue equals the source exactly (109,846,381.399888). Microsoft's DW stores line amounts as `money` (4 decimals) and differs by at most 0.0003 per order; apart from that and the 64 lines of D27, `fact_sales` matches Microsoft's DW on lines, revenue and cost. | Sales checks: DW reconciliation; `tests/test_fact_sales.sql` test 1 |

### fact_sales_quota (one row per salesperson per quota period)

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D30 | A quota covers the 3 months from its quota date until the day before the next one; the last period ends 2025-05-27. | "After" gives ratio 0.860 and 0 zero-sales quotas; "before" gives 0.809 and 4. | Quota checks: check 3 |
| D31 | Actual vs quota is compared by quota period (`dim_date.quota_period_start`), not calendar quarter. | One company quota calendar: 12 dates, 3 months apart, on days 28-30, not calendar quarters. | Quota checks: checks 2 and A |
| D32 | Territory rule: covering period, else nearest period, else region group from the person's orders (region-level row), else unknown. Recorded in `territory_source`. | 132 rows covered; 7 rows (salespeople 280 and 284) resolved by nearest period, confirmed by their orders in Northwest; 274, 285, 287 sell in one region group each and are the regional sales managers by job title. | Quota checks: territory checks; Employee checks: check 4 |

### fact_finance (one row per month x organisation x department group x account x scenario x entry type)

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D33 | Period date = month-end of the shifted date; 37 months, May 2022 to May 2025. | The source has 5 months with two dates; 3 are late month-ends that separate after the shift. | Finance checks: checks 2, 2c, 2d |
| D34 | Year-end adjustment rows are kept separate with `entry_type`. | 6 collisions, only in the two year-end months; merging would hide adjustments. | Finance checks: check 2d |
| D35 | Corporate department group rows are its own data, shown as "Corporate (direct)". | 8,501 of 8,843 Corporate rows differ from its children's total; 342 equal rows are spread over 22 accounts and 112 equal the sum of two children, ruling out copies. | Finance checks: checks A-D |
| D36 | Finance amounts are in local currency and are converted to USD: monthly average rate for income and expenses, month-end rate for the balance sheet, looked up on the original DW date; USD at 1.0; statistical accounts not converted. Keep `amount_local`, `currency_code`, `exchange_rate`, `amount_usd`. | Salaries per head and rent per square foot for Australia and Canada sat above every US division; after conversion, salaries per head for all four non-US units fell into the US range. Rate = USD per unit. | Finance checks: currency evidence 3 and conversion tests |
| D37 | Local currency view on finance pages is a Should item; USD is the default. | Local managers think in local currency; totals need one currency. Only shown when one currency is selected. | Step 2.4 |
| D38 | Signs come from the account operator; the sign of each account towards Net Income is stored. | Tested: revenue added, costs subtracted; margins 67-70% gross, 25-28% operating, 19-22% net. | Finance dimension checks: checks 1 and 2 |
| D39 | Balance sheet rows are month-end balances; measures take the closing balance of the last month that has balance sheet rows. | Land and buildings are positive in every month (movements would be mostly zero). May 2025 has no balance sheet rows. | Finance dimension checks: check 3b |
| D40 | Finance and sales are never combined in one KPI. | They agree in total (about 6%) but not per organisation. | Finance checks: currency check (F8 finding) |
| D41 | HR KPIs use HR data, never the finance Headcount account. | Avoids two different headcount numbers. | Step 2.4 |
| D97 | Balance sheet amounts are added only within Assets or within Liabilities and Owners Equity, never across the two; no balance sheet sign column is stored. | The only balance sheet account with a "-" operator is Liabilities and Owners Equity (account 20); every account inside either side adds with "+". Adding both sides gives 0 by design. | Finance dimension checks: check 5 |

### fact_purchase (one row per purchase order line)

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D42 | Spend = accepted goods value (stocked qty x order price), across all statuses. | Pending and Approved orders hold received goods; "Rejected" means goods rejected on arrival. Ordered = accepted + rejected + short-delivered value for every status. No invoice data exists. | Purchase checks: checks 4 and B |
| D43 | OTIF is the main vendor KPI, with unit fill rate and rejection %; only lines due by the module's last data date and with a valid due date count. | OTIF varies (89.3%) while on-time alone is 100%; all 380 short deliveries are past due. | Purchase checks: checks F and G |
| D44 | Freight is allocated to lines by value, with the largest-remainder method. | Weight is missing for 94% of purchased products; rounding is the only cause of the allocation gap, and the remainder method makes it exact. | Purchase checks: checks C, D, E |
| D45 | Inactive vendors are kept; 7 lines with a due date before the order date are flagged `is_due_date_invalid`. | Inactive vendors have 203 orders of history; the 7 lines are data entry errors. | Purchase checks: checks 8 and A |

### fact_work_order (one row per work order)

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D46 | Scrap rate (units) is the main P6 KPI; scrap cost is stored but hidden. | Scrap cost can be valued for only 21.4% of scrapped units: 18 made components have no cost anywhere in the source. | Work order checks: cost gap and component checks |
| D47 | On-time production is a Must KPI. | 31.4% of work orders finish after their due date (always start + 11 days). | Work order checks: check 4 |
| D48 | `dim_location` is not linked to work orders. | The WorkOrder table has no location column. | Work order checks |

### Inventory

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D49 | `fact_inventory_current` is the only inventory fact; `fact_inventory_daily` is not built. | The DW snapshot agrees with OLTP stock on 0 of 432 products, has 3,319 negative balances and duplicate product versions per day. | Inventory daily checks |
| D50 | Location type: work centre if cost rate or hours are above 0, otherwise storage. | Cost rate, hours and routing steps agree on all 14 locations. | Inventory current checks: check C |
| D51 | Stock status compares reorder point (trigger) and safety stock (minimum) with the inventory position (on hand + open purchase quantity). Available (storage) stock is shown separately. | Standard reorder logic; column roles taken from the source descriptions. | Inventory current checks: checks B and D |
| D52 | Active products with no inventory row get one zero-quantity row at "No stock location". | 54 finished products on sale have no stock row and would vanish from the reorder list. | Inventory current checks: check D |
| D53 | Unit cost = standard cost, else last purchase price, else NULL. | Raises internal-part units with a cost from 2.8% to 91.5% (93.5% of all stock). | Inventory current checks: check E |
| D54 | The stock trend (P5) moves to open items; it could be rebuilt from OLTP transaction history. | Keeps one source of truth for stock. | Inventory daily checks |

### fact_headcount_monthly (one row per employee per month-end)

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D55 | Department, shift and pay rate are looked up as of each month-end. | History is clean: one open period per employee, no overlaps, no gaps; first department starts on the hire date. | Headcount checks: checks 1-3 and 5 |
| D56 | Pay is pay rate per hour for everyone, so averages compare across employees. | Source description: "Salary hourly rate". | Headcount checks: check 4 |
| D57 | Headcount is semi-additive; revenue per employee uses average headcount of the period. | Headcount cannot be summed over months. | Step 2.4 |
| D58 | Snapshot month-ends from April 2022 to October 2025. | First and last months with operational activity. | Date checks |

## 6. Dimensions

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D59 | Every dimension has a surrogate key; special keys -1 = Unknown (data missing) and -2 = Not applicable (value cannot exist). | Separates data problems from normal cases, e.g. online orders have no salesperson. | Territory checks |
| D60 | `dim_product`: Type 1; internal parts get category "Internal parts"; missing attributes "N/A"; zero cost and price stored as NULL. | Avoids confusion with the sellable "Components" category; cost history lives in the facts. | Product checks |
| D61 | `dim_territory`: 10 territories plus 3 region-level rows (`is_region_level`). | Regional managers' quotas cover a whole region group. DW's extra territory row is an unknown member. | Territory checks |
| D62 | `dim_employee` holds non-sensitive attributes; sensitive ones (age band, gender, salaried flag, hire date, leave hours) go to `dim_employee_hr`. Birth date is not stored. | Row-level security filters rows, not columns; regional managers need salesperson names but not personal HR details. Data minimisation. | Security design, Step 2.6 |
| D63 | Manager derived from the organization hierarchy; the top employee's manager is Not applicable. | 283 found directly; the 6 who report to the top employee are resolved through it. | Employee checks: check 3 |
| D64 | Average pay uses complementary suppression: shown by department group, and by department only when it has 5 or more employees and no department in its group is hidden. | A minimum group size alone leaks hidden values by subtraction (Executive has 2 employees). | Employee checks: check 6 |
| D65 | `dim_customer`: individuals shown by account number only, stores by name (plus account number when the name is shared); `has_orders` flag; customer counts use customers with orders. | Privacy; 701 store-only rows never order; 2 store names are shared. | Customer checks |
| D66 | `dim_promotion` needs no Not applicable row; discount amounts always come from the line discount. | "No Discount" is a real offer covering 115,884 lines; 2,151 lines on discounted offers received no discount, none the other way. | Reference checks: checks 1, 2, 2b |
| D67 | No vendor country column. | All 104 vendors are in the United States. | Reference checks: checks 4 and 5 |
| D68 | `dim_account`: statement type, sign towards Net Income, levels 1-6 flattened (leaf name repeated), tree sort order. | Correct profit lines and a naturally ordered income statement. | Finance dimension checks |
| D69 | `dim_organization`: levels 1-3 flattened (leaf name repeated), region group from level 1, mapped sales territory, currency. | The tree is ragged (US divisions one level deeper); level 1 matches the region groups. | Finance dimension checks: check 4 |
| D70 | `dim_finance_department_group` includes "Corporate (direct)". | Holds Corporate's own rows under the Corporate total. | Finance checks |
| D93 | Customer geography stops at country and sales territory; Person.Address and Person.StateProvince are not loaded, although the inventory first marked them "Use". | Territory and country (both in `dim_territory`) already serve maps, slicers and row-level security; city and state would add a staging table, a dimension change and tests. Less personal location data enters the warehouse. | Inventory (updated); review of 10 Nov 2026 |
| D94 | Finance units are linked to sales territories through an explicit table, `etl.org_territory_map` (9 rows), never by ID or by name rules. | The IDs differ between the two databases (finance Northeast Division = 3, sales territory 3 = Central); a reviewable table cannot silently mismatch. Map names are checked against the source by test. | `sql/02_warehouse/21_dim_organization.sql`, `tests/test_dim_finance.sql` test 4 |
| D96 | `dim_account` sort order follows the account tree, with siblings ordered by account code as text. | Reproduces the source's own order: as text, Commissions (6100) falls between Labor Expenses (600) and Travel Expenses (620); as a number it would fall after Depreciation (680). | `tests/test_dim_finance.sql` test 4 (sort order rows) |
| D99 | `dim_account` and `dim_organization` carry `is_leaf`. | Finance facts link only to leaf accounts and leaf units; the flag lets checks and reports separate leaves from totals. | `tests/test_dim_finance.sql` test 4 (72 leaf accounts, 9 leaf units) |

## 7. Security

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D71 | Two roles: Executive and Regional Manager, with dynamic row-level security through `dw.security_user_region` and three demo users. | Managers are added or moved by editing data, not the report. | Step 2.6 |
| D72 | Regional managers see their region's sales, quotas, salespeople and finance, plus company-wide inventory. They do not see HR, purchasing, production, `dim_employee_hr` or unknown (-1) rows. | Region exists only for sales and finance; stock is not sensitive and helps sales; HR is sensitive. | Step 2.6 |
| D73 | A user missing from the mapping table sees no data. | Secure by default. | Step 2.6 |
| D74 | Security is demonstrated with "View as" in Power BI Desktop; the .pbix file itself is not protected. | Row-level security is enforced when content is shared through the Power BI Service. | Step 2.6 |
| D95 | Region group of a finance unit: a leaf unit takes the region group of its mapped territory; a parent unit takes the one group shared by all its leaves, or "All regions" when they differ; a leaf unit missing from the map gets "N/A" and matches no regional manager. | Security fails closed: a new unit stays hidden from regional managers until it is mapped, and it never changes its parent's region. | `tests/test_dim_finance.sql` test 6g |

## 8. Pipeline

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D76 | Facts are fully reloaded on every run; dimensions are merged (update existing, insert new). | Volumes are small (largest source table 121,317 rows), so a full reload is fast and never misses updates or deletes; merged dimensions keep surrogate keys stable. Incremental loading by `ModifiedDate` is the next step if volumes grow. | Architecture, Step 2.7 |
| D77 | Data quality checks run on every load; errors stop the job, warnings are logged and reported. | Half-loaded or broken data never reaches the report; known anomalies stay visible. | Architecture, Step 2.7 |
| D78 | The SQL Server Agent job runs nightly at 02:00. | Outside working hours. | Architecture, Step 2.7 |
| D100 | The pipeline compares every staging row count with its source right after the staging load and stops before any dimension runs if a table is empty or a count differs. | An empty staging makes every dimension load mark its rows as no longer in the source; this happened in testing on 10 Nov 2026 (all 13 territory rows; all scenario, organization and account rows; department group 7, the only group checked). The cause of the empty staging was not confirmed. Stopping early keeps the warehouse unchanged. | `docs/test_results.md`, B3d notes |
| D103 | Facts have foreign keys to `dim_date` and to every dimension they use. | The database itself refuses a row that points to a missing date or dimension row. Dimensions never delete rows (D87), so the keys never block a dimension load. The full sales reload with keys took 2 and 4 seconds in the two test runs of 10 Nov 2026. | `sql/02_warehouse/23_fact_sales.sql`; `tests/test_fact_sales.sql` test 7 |
| D106 | Each fact load refuses to run when its main staging tables are empty (error 50002) and opens its own transaction only when the caller has none. | A fact is emptied and reloaded (D76), so an empty staging would empty it for nothing. A procedure that rolls back its caller's transaction makes SQL Server raise error 266; leaving the caller's transaction alone also lets tests run inside rolled-back transactions. | `tests/test_fact_sales.sql` tests 6 and 6b |

## 9. Staging

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D79 | 36 staging tables, prefixed by source: `stg.aw_<table>` (AdventureWorks2025) and `stg.awdw_<table>` (AdventureWorksDW2025). | Every staging table shows its source and cannot be confused with the `dw` schema. Traced to every fact and dimension. | `sql/02_warehouse/03_staging_tables.sql` |
| D80 | Staging copies only the columns in use, keeps source column names and exact source types, and has no keys or constraints; every row has `batch_id` and `loaded_at`. | Raw, traceable copy that accepts source data as it is; types verified against the live source by test (194 of 194 columns match). | `tests/test_staging.sql`, test 3 |
| D81 | From Person only employees (types EM and SP) are copied; birth date is kept in staging only; the hierarchy node is stored as text with its parent path. | Individual customer names never enter the warehouse; ages are derived from birth date, which is not exposed to Power BI. | `sql/02_warehouse/04_load_staging.sql` |
| D82 | Staging tables are copied one after another, not in one consistent snapshot. Accepted for a nightly load of static data; a data quality check reports order lines without a header. | Snapshot isolation would require changing the source database settings. | Step B2 |

## 10. Dimension loading

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D83 | Dimensions are loaded with UPDATE (changed rows) then INSERT (new rows), not MERGE. Change detection uses NOT EXISTS ... INTERSECT, which treats NULLs as equal. | Same result as D76; MERGE has a history of bugs and edge cases in SQL Server, and two plain statements are easier to read and test. | `sql/02_warehouse/06_dim_date.sql` |
| D84 | Every dimension row carries `inserted_batch_id` and `updated_batch_id`. | Shows when each row first appeared and last changed. | `sql/02_warehouse/06_dim_date.sql` |
| D85 | Shared constants (HR and DW date shifts, fiscal start month) live once in `etl.setting` and are read through `etl.get_setting_int`, which fails if a value is missing. | No number typed in several procedures; one place to change. | `sql/02_warehouse/05_etl_settings.sql` |
| D86 | `dim_date` range is calculated from staging on every run (whole years around all fact and hire dates); weekday by arithmetic (Monday = 1) and names from fixed lists, independent of server settings; dates are never deleted; no relative-date columns; the load checks compatibility level 160+ for GENERATE_SERIES. | The calendar extends itself with new data and cannot change with DATEFIRST or language settings; "current" periods depend on today, which D24 rules out. | `sql/02_warehouse/06_dim_date.sql`, `tests/test_dim_date.sql` |
| D87 | Source dimensions share one pattern: identity surrogate key; fixed special rows (-1 Unknown, -2 Not applicable) created once by the load; business key unique for real rows (filtered unique index); `row_type` (Source, Derived, Unknown, Not applicable); rows that leave the source are kept with `is_in_source = 0` (soft delete). | Facts may still point to old rows, so deleting would break history; special and derived rows are easy to recognise. Soft delete proven by a rolled-back test. | `sql/02_warehouse/07_dim_product.sql` to `14_dim_scrap_reason.sql`, `tests/test_dim_source.sql` |
| D88 | Region-level territory rows use the business key "REGION-" + region group name and are built from the distinct region groups in staging. | A new region group gets its row automatically, without code changes. | `sql/02_warehouse/08_dim_territory.sql` |
| D89 | Code labels come from the full source descriptions (product line, class, style, credit rating); missing text is "N/A"; special-row text that would not fit a short column becomes "N/A". | Labels are traceable to the source; special rows can never fail on column length. | `sql/02_warehouse/07_dim_product.sql`, `12_dim_vendor.sql` |
| D90 | Manager: parent path found -> that employee; parent path "/" -> the top employee (the only one without a node); the top employee and the special rows have no parent (NULL); otherwise -1. Loaded in a second pass after all employees have keys. `manager_key` may be empty because it describes a hierarchy, not a link to a fact; the only other key allowed to be empty is `ship_date_key` (D102). | Proven on staging: the Chief Executive Officer has no node and exactly 6 level-1 employees have parent "/". A hierarchy root needs an empty parent, and a row pointing to itself is a loop that Power BI's PATH function rejects (found by test: the first version made row -2 its own manager). | `sql/02_warehouse/17_dim_employee.sql`, `tests/test_dim_employee.sql` |
| D91 | `dim_employee_hr` uses the same key as `dim_employee`; its age band is the exact age (birthday counted) on `etl.setting` hr_as_of_date = 2025-10-31, the last month-end of the headcount snapshot. | One key for both tables; "current" HR values refer to the end of the HR data, never today (D24). | `sql/02_warehouse/18_dim_employee_hr.sql`, `05_etl_settings.sql` |
| D92 | Buyers are employees with job title Buyer, Purchasing Assistant or Purchasing Manager (12). | These are exactly the titles that place purchase orders. | Purchase checks: check 7 |
| D98 | Hierarchy dimensions check the shape they rely on and stop the load if it changes: department groups two levels, organization at most four, accounts at most six levels with top accounts 1, 4 and 9500 only, and every map row pointing to a real territory. | Flattened level columns and statement rules would otherwise misplace rows without any error. | `tests/test_dim_finance.sql` tests 6c, 6e, 6f, 6i, 6j |

## 11. Documentation

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D75 | Design documents are Markdown files in `docs/design/` with Mermaid diagrams; the data dictionary is generated after the build. | Versioned with the code and rendered by GitHub; the dictionary always matches the real tables. | Step 2.7 |
