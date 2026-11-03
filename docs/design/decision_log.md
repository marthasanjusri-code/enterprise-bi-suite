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
| D13 | The model is designed from business questions S1-S9, F1-F8, H1-H5, P1-P9 and an executive overview. | Tables exist only to answer questions. | Step 2.2 |
| D14 | Revenue = sum of line totals (after discount, before tax and freight), excluding Rejected and Cancelled orders. | Standard revenue definition; tax and freight are not sales income. Line totals add up to every order's SubTotal. | Sales checks: checks 2 and 3 |
| D15 | HR "top performing employees" is not built. | The source has no performance data for non-sales roles; pay or tenure as a proxy would be misleading and unfair. | Step 2.2 |
| D16 | "Top performing salespeople" (S9) is built from revenue and quota attainment. | Salesperson performance is measurable in the data. | Step 2.2 |
| D17 | Measures use NULL for unknown values; keys never use NULL. | Aggregates skip NULL, so averages stay correct and coverage can be counted. A NULL key would make rows disappear from visuals. | Work order checks: cost decisions |
| D18 | A KPI that never varies is kept as a hidden measure, not shown: sales on-time shipping (always 7-8 days), vendor on-time delivery (100%). | A constant KPI gives no information; keeping the data allows it to be shown if data changes. | Sales checks: check 6; Purchase checks: check G |

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

## 7. Security

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D71 | Two roles: Executive and Regional Manager, with dynamic row-level security through `dw.security_user_region` and three demo users. | Managers are added or moved by editing data, not the report. | Step 2.6 |
| D72 | Regional managers see their region's sales, quotas, salespeople and finance, plus company-wide inventory. They do not see HR, purchasing, production, `dim_employee_hr` or unknown (-1) rows. | Region exists only for sales and finance; stock is not sensitive and helps sales; HR is sensitive. | Step 2.6 |
| D73 | A user missing from the mapping table sees no data. | Secure by default. | Step 2.6 |
| D74 | Security is demonstrated with "View as" in Power BI Desktop; the .pbix file itself is not protected. | Row-level security is enforced when content is shared through the Power BI Service. | Step 2.6 |

## 8. Documentation

| ID | Decision | Reason | Evidence |
|---|---|---|---|
| D75 | Design documents are Markdown files in `docs/design/` with Mermaid diagrams; the data dictionary is generated after the build. | Versioned with the code and rendered by GitHub; the dictionary always matches the real tables. | Step 2.7 |