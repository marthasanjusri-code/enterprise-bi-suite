# Test Results

Results of every test script in `tests/`, newest build step last. Each test lists what was
expected and what was measured. Tests are re-run whenever the code they cover changes.

---

## B1: Warehouse database and ETL logging framework

**Script:** `tests/test_etl_framework.sql` | **Run:** 2026-11-03 | **Result:** 5 of 5 passed

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Database settings | EnterpriseBI_DW, SIMPLE recovery, 3 schemas | EnterpriseBI_DW, SIMPLE, 3 | Pass |
| 2 | Objects exist | 3 tables, 4 procedures | 3 tables, 4 procedures | Pass |
| 3 | A full run (batch, step, check) | Succeeded, 10 / 10 rows, end times set, 1 check row | As expected | Pass |
| 4 | Invalid status rejected | Rejected by CHECK constraint | Rejected | Pass |
| 5 | Nothing left after rollback | 0 / 0 / 0 rows | 0 / 0 / 0 | Pass |

Note: batch IDs are not consecutive (2, then 2004). SQL Server reserves identity values in
blocks and loses unused ones on restart; IDs only need to be unique.

---

## B2: Staging tables and staging load

**Script:** `tests/test_staging.sql` | **Run:** 2026-11-04 | **Result:** 7 of 7 passed

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Row count of every staging table vs source | 36 tables equal | 36 of 36 equal (Person = 290 employees) | Pass |
| 2 | Key totals vs source (sales and purchase lines, subtotal, freight, received qty, scrap, inventory, finance amount, exchange rates) | 9 equal | 9 of 9 equal to the cent (sales lines 109,846,381.40) | Pass |
| 3 | Type, length, precision and scale of every column vs the live source | 194 compared, 194 match | 194 / 194 / 0 missing / 0 differ | Pass |
| 3b | Mismatch list | No rows | No rows | Pass |
| 4 | Hierarchy stored as text | 290 employees, 1 without node, 289 with parent path | 290 / 1 / 289 | Pass |
| 5 | Load log of the batch | 36 steps succeeded, counts equal | 36 / 36 / 36, 316,932 rows (equals the sum of test 1) | Pass |
| 6 | Re-run gives the same counts | 36 compared, 0 changed | 36 / 0 | Pass |

Fixes during testing:
- Test 3 first failed to run (arithmetic overflow): `ISNULL(NUMERIC_PRECISION, -9)` keeps the
  tinyint type of its first argument, which cannot hold -9. Replaced with `IS DISTINCT FROM`.
  Collations were checked and ruled out as a cause (all four are SQL_Latin1_General_CP1_CI_AS).

---

## B3a: Settings table and calendar dimension

**Script:** `tests/test_dim_date.sql` | **Run:** 2026-11-04 | **Result:** 7 of 7 passed

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Settings and compatibility level | 4017, 4170, 7, level 160 or higher | 4017, 4170, 7, 170 | Pass |
| 2 | Range and completeness | 2017-01-01 to 2025-12-31, 3,287 rows, 0 missing days | As expected | Pass |
| 3 | Known dates (weekday, ISO week and year, fiscal year, quarter and month, month end, quota period) | 18 checks equal | 18 of 18 equal | Pass |
| 4 | Quota periods | 12 periods, 11 linked, last ends 2025-05-27 | 12 / 11 / 2025-05-27 | Pass |
| 5 | Every fact date exists in the calendar | 0 missing | 1,343 distinct fact dates, 0 missing | Pass |
| 6 | Lineage | 0 rows without batch ids | 0 / 0 | Pass |
| 7 | Re-run writes nothing | 3,287 rows, 0 written | 3,287 read, 0 written, Succeeded | Pass |

Notes:
- `05_etl_settings.sql` first run: 0 rows updated, 3 inserted, as expected for a new table.
- Test 3 includes the ISO year trap: 2025-12-29 belongs to ISO week 1 of 2026 while its calendar
  year is 2025.

---

## B3b: Eight source dimensions

**Script:** `tests/test_dim_source.sql` | **Run:** 2026-11-04 | **Result:** 7 of 7 passed

Dimensions: product, territory, customer, promotion, ship method, vendor, location, scrap reason.

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Rows = source + special rows | 505, 14, 19,821, 17, 6, 105, 16, 18 | As expected (territory 10 + 3 region-level + 1) | Pass |
| 2 | Business keys unique | 0 duplicates in all 8 | 0 in all 8 | Pass |
| 3 | Special rows with fixed keys | 10 rows (-1 in all, -2 in location and scrap reason) | 10 of 10 | Pass |
| 4 | Rules (internal parts, NULL costs, code labels, discontinued, region rows, customer labels, customers with orders, promotions used, credit ratings, location types) | 17 checks equal | 17 of 17 equal (e.g. 209 internal parts, 19,119 customers with orders, Paint Shop = Storage) | Pass |
| 5 | Lineage | 0 rows without batch ids | 0 in all 8 | Pass |
| 6 | Soft delete (rolled-back transaction: ship method 5 removed from staging) | Row kept with is_in_source = 0, 1 row written; restored after rollback | Inside: 6 rows, 0, 1 written. After rollback: 6 rows, 1 | Pass |
| 7 | Re-run of all eight | 8 steps succeeded, 0 rows written | 8 / 8 / 0 | Pass |

---

## B3c: Employee, employee HR, department and shift dimensions

**Script:** `tests/test_dim_employee.sql` | **Run:** 2026-11-04 | **Result:** 5 of 5 passed (after one fix)

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Row counts | Department 17, shift 4, employee 292, employee HR 291 | As expected | Pass |
| 2 | Rules (same keys both ways, managers, roles, departments, gender, pay type, age bands, shifted hire dates, no birth date column, special row) | 21 checks equal | 21 of 21 equal (289 with a manager, CEO is the root, 6 report to the CEO, 0 loops, 17 salespeople, 12 buyers, Production 179) | Pass |
| 3 | Age bands on 2025-10-31 (information) | 290 employees | Under 30: 95, 30-39: 112, 40-49: 57, 50-59: 20, 60 and over: 6 | Pass |
| 4 | Lineage | 0 rows without batch ids | 0 in all four | Pass |
| 5 | Re-run | 4 steps succeeded, 0 rows written | 4 / 4 / 0 | Pass |

Fix during testing:
- The first run failed one rule: one row pointed to itself as manager. Confirmed by query: special
  row -2 "No salesperson" had manager -2, and the CEO's manager was also -2, so every path up the
  hierarchy ended in a loop (Power BI's PATH function rejects loops). The CEO and the special rows
  now have no parent (NULL); recorded in D90.


---

## B3d: Finance dimensions (scenario, finance department group, organization, account)

**Script:** `tests/test_dim_finance.sql` | **Run:** 2026-11-10 | **Result:** 16 of 16 passed (second run)

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Rows = source + special rows | 4, 8, 15, 100 | As expected | Pass |
| 2 | Business keys unique | 0 duplicates in all 4 | 0 in all 4 | Pass |
| 3 | Special rows with fixed keys | -1 Unknown in all 4 | 4 of 4 | Pass |
| 4 | Rules (scenario names, Corporate (direct), unit levels, region groups, currencies, territory map, statements, signs, profit-line leaf counts, levels, sort order, 14 units and 16 accounts in full) | 91 checks equal | 91 of 91 equal (e.g. 72 leaf accounts; signs +1: 12, -1: 36, 0: 51; net income 35 leaves, 6 added, 29 subtracted; United Kingdom is the only territory without a finance unit) | Pass |
| 5 | Lineage | 0 rows without batch ids | 0 in all 4 | Pass |
| 6a | Soft delete, scenario 3 (rolled back) | Inside: 4 rows, 0, 1 written; after rollback 1 | 4 / 0 / 1; 1 | Pass |
| 6b | Soft delete, department group 7 (rolled back) | Inside: 8 rows, 0, 1 written; after rollback 1 | 8 / 0 / 1; 1 | Pass |
| 6c | Guard: third level in department groups | Rejected, 8 rows | Rejected, 8 | Pass |
| 6d | Soft delete, organization unit 12 (rolled back) | Inside: 15 rows, 0, 1 written; after rollback 1 | 15 / 0 / 1; 1 | Pass |
| 6e | Guard: fifth organization level | Rejected, 15 rows | Rejected, 15 | Pass |
| 6f | Guard: map row to a missing territory | Rejected, 15 rows | Rejected, 15 | Pass |
| 6g | New unit not in the map | Region N/A, territory N/A, leaf; parent stays North America | N/A / N/A / 1 / North America | Pass |
| 6h | Soft delete, account 99 (rolled back) | Inside: 100 rows, 0, 1 written; after rollback 1 | 100 / 0 / 1; 1 | Pass |
| 6i | Guard: seventh account level | Rejected, 100 rows | Rejected, 100 | Pass |
| 6j | Guard: unknown top account | Rejected, 100 rows | Rejected, 100 | Pass |
| 7 | Re-run of all five loads | 5 steps succeeded, 0 rows written | 5 / 5 / 0 | Pass |

Notes:
- The first run failed tests 1 and 4 and could not run the guard tests: all 36 staging tables
  were empty (cause not confirmed), so the loads marked rows as no longer in the source:
  all 13 territory rows, all scenario, organization and account rows, and department group 7
  (the only group the first run showed). No code was wrong. Staging
  was reloaded (batch 3068, 316,932 rows, equal to test B2), and the second run passed. The
  soft-deleted rows returned to `is_in_source = 1`, which also proves that rows coming back to
  the source are restored.
- Fix to the test: a precondition at the top now stops the script when staging is empty.
- Balance sheet signs: the only balance sheet account with a `-` operator is
  "Liabilities and Owners Equity" (account 20). Every account inside Assets and inside
  Liabilities and Owners Equity adds up with `+`, so balance sheet totals are correct as long
  as a measure never adds the two sides together.
- The full pipeline (Step B5) will check staging row counts right after the staging load and
  stop before the dimensions run, so an empty staging can never mark the warehouse as deleted.

---

## B4a: Sales fact

**Script:** `tests/test_fact_sales.sql` | **Run:** 2026-11-10 (batch 4044) | **Result:** 7 of 7 passed (test 4 is information)

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Grain and totals vs staging | 6 checks equal | 6 of 6 (121,317 lines; line_total 109,846,381.399888 = staging; 109,846,381.40 to the cent as in B2; order_qty 274,914; 0 orders differ from SubTotal) | Pass |
| 2 | Keys | 10 checks equal | 10 of 10 (0 unknown keys; 60,398 online lines with "No salesperson"; 0 lines without ship date; 0 date keys differ from staging) | Pass |
| 3 | Rules (amounts, cost rule D26, channel, status D104) | 12 checks equal | 12 of 12 (64 estimated-cost lines on 25 products; 0 lines without cost; 0 lines whose cost differs from the period containing the order date; 0 status texts differ from the source function) | Pass |
| 4 | Revenue, cost and margin by channel (information) | - | Online 60,398 lines, revenue 29,358,677.22, cost 17,277,793.58, margin 41.15%; Reseller 60,919 lines, revenue 80,487,704.18, cost 80,010,807.23, margin 0.59% | - |
| 5 | Lineage | 0 rows without lineage, 1 batch | 0 / 1 | Pass |
| 6 | Failed load keeps the last good data (duplicate line added to staging) | failed, 121,317 rows kept, step Failed, duplicate removed | failed / 121,317 / Failed / 0 | Pass |
| 6b | Empty staging is refused (D106, rolled back) | refused, 121,317 fact rows, 121,317 staging lines, 0 open transactions | refused / 121,317 / 121,317 / 0 | Pass |
| 7 | Re-run | Succeeded, 121,317 rows, 109,846,381.40, 0 rows from other batches | Succeeded / 121,317 / 109,846,381.40 / 0; load 4 seconds | Pass |

Notes:
- Reconciliation with Microsoft's DW (D105, `fact_sales_checks.sql`): Online equals DW Internet sales on
  lines, revenue and cost. Reseller equals DW Reseller sales after removing the 64 estimated-cost lines
  Microsoft dropped (D27): lines and cost equal, revenue differs by 0.02, because DW stores line amounts
  with 4 decimals (largest difference per order 0.000308). The low reseller margin is in the source data.
- An earlier run on the same day (batch 3105, before D104 and D106) passed every check it had; its reload
  took 2 seconds.
- This run took about 4 minutes in total, while the earlier run took seconds. The cause was not
  identified; the results are not affected.

---

## B4b: Sales quota and work order facts

**Script:** `tests/test_fact_quota_work_order.sql` | **Run:** 2026-11-10 (batch 4048) | **Result:** 6 of 6 passed (test 3 is information)

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | `fact_sales_quota` against staging and the quota checks | 19 checks equal | 19 of 19 (163 rows, 17 salespeople, 12 quota dates 2022-05-30 to 2025-02-28, quota total 95,714,000.00; territory source history 132, nearest 7 (salespeople 280 and 284, all Northwest), region from orders 24 (274 North America, 285 Pacific, 287 Europe), unknown 0; every period starts on its quota date and lasts 3 months; last period ends 2025-05-27) | Pass |
| 2 | `fact_work_order` against staging and the work order checks | 26 checks equal | 26 of 26 (72,591 orders on 238 products; 4,507,721 ordered, 10,651 scrapped; 729 orders with scrap, 16 reasons; 22,790 finished late; 10 to 32 days to finish; due date always start + 11 days; cost source history 35,297, carried back 7,307, carried forward 6,439, standard cost 5,044 = staging; 0 starts in a gap; scrapped units with / without a cost 2,282 / 8,369) | Pass |
| 3 | Work orders by cost source (information) | - | history 35,297 orders, 1,194 scrapped units; carried back 7,307, 502; carried forward 6,439, 440; standard cost 5,044, 146; unknown 18,504, 8,369 | - |
| 4 | Lineage | 0 rows without lineage, 1 batch, both facts | 0 / 1 and 0 / 1 | Pass |
| 5a | Empty quota staging is refused (D106, rolled back) | refused, 163, 163, 0 open transactions | refused / 163 / 163 / 0 | Pass |
| 5b | Empty work order staging is refused (D106, rolled back) | refused, 72,591, 72,591, 0 open transactions | refused / 72,591 / 72,591 / 0 | Pass |
| 6 | Re-run | Both Succeeded, 163 and 72,591 rows, 0 rows from other batches | As expected; 0 and 3 seconds | Pass |

Notes:
- In test 3 the unknown cost source shows a scrap cost total of 0.00: its 8,369 scrapped units have no
  cost (stored as empty), and a sum skips empty values. Scrap cost must therefore always be shown with
  its coverage (D46).
- Standard cost covers 146 scrapped units: 143 on components with a standard cost and 3 on the two
  finished goods without cost history, as in the work order checks.

---

## B4c: Purchase, current inventory and monthly headcount facts

**Script:** `tests/test_fact_purchase_inventory_headcount.sql` | **Run:** 2026-11-10 (batch 4052) | **Result:** 8 of 8 passed (test 4 is information)

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | `fact_purchase` against staging and the purchase checks | 22 checks equal | 22 of 22 (8,845 lines, 4,012 orders; by status Approved 57, Complete 8,169, Pending 477, Rejected 142, texts equal to the source function; 2,348,637 ordered, 2,327,299 received, 72,700 rejected units; ordered value 63,791,994.838 = staging and = accepted + rejected + short-delivered on every line; spend 61.21 M; 380 short-delivered lines, 563 with rejects; freight 1,583,978.23 allocated exactly on every order; 7 invalid due dates on orders 4003 and 4006; lead time 10 to 120 days; 12 buyers; 9 to 25 days to ship; 190 orders with tied largest lines) | Pass |
| 2 | `fact_inventory_current` against staging and the inventory checks | 15 checks equal | 15 of 15 (1,069 source rows on 432 products and 14 locations, plus 54 zero rows; snapshot 2025-08-11; 335,974 units; units by cost source 85,166 / 228,992 / 21,816; 314,158 units with a cost; value 19.23 M finished goods, 0.87 M and 8.43 M internal parts) | Pass |
| 3 | `fact_headcount_monthly` against staging and the headcount checks | 12 checks equal | 12 of 12 (12,333 rows = independent count; 43 month-ends 2022-04-30 to 2025-10-31; headcount 283 / 287 / 290 / 290 at the four sample dates; 0 unknown keys; 0 rows without pay rate; 16 hires in the window; department, pay rate and age band at 2025-10-31 equal to staging and `dim_employee_hr`) | Pass |
| 4 | Inventory by cost source, headcount at six month-ends (information) | - | last purchase price 533 rows, 228,992 units, 8,429,586.96; standard cost 541, 85,166, 20,092,679.17; unknown 49, 21,816, no value. Headcount 274 at 2022-04-30, 283 from 2022-05-31 (9 hires), 290 in Aug-Oct 2025; average pay rate 17.40 to 18.19 | - |
| 5 | Lineage | 0 rows without lineage, 1 batch, all three facts | 0 / 1 for each | Pass |
| 6a | Empty purchase staging is refused (D106, rolled back) | refused, 8,845, 8,845, 0 | As expected | Pass |
| 6b | Empty inventory staging is refused | refused, 1,123, 1,069, 0 | As expected | Pass |
| 6c | Empty employee staging is refused | refused, 12,333, 290, 0 | As expected | Pass |
| 7 | Re-run | 3 steps Succeeded, 0 rows from other batches | 8,845 / 1,123 / 12,333 rows; 1, 0 and 0 seconds | Pass |

---

## B4d: Finance fact

**Script:** `tests/test_fact_finance.sql` | **Run:** 2026-11-11 (batch 4060) | **Result:** 5 of 5 passed (second run; test 3 is information)

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Grain, dates, keys and amounts against staging and the finance checks | 18 checks equal | 18 of 18 (39,409 rows; 37 month-end periods 2022-05-31 to 2025-05-31; 46 adjustment rows on 2011-12-28 and 2012-12-27 in May 2023 and May 2024; 6 grain pairs of a regular and an adjustment row; 0 unknown keys; 0 rows on parent accounts or units; 8,843 Corporate (direct) rows; amount_local 1,358,640,412.70 = staging and equal on every row; balance sheet rows AUD 350, CAD 1,050, EUR 1,402, USD 5,322; May 2025 balance sheet 6 rows on 3 units netting to 0, only accounts 3010 and 3020; last month with asset rows 2025-04-30) | Pass |
| 2 | Currency conversion (D36) | 8 checks equal | 8 of 8 (statistical rows without rate; every money row converted; USD at 1.0; monthly average and end-of-day rates equal to a separate recomputation; amount_usd = amount_local x rate; salaries per head in USD Australia 4,303, Canada 4,905, France 3,145, Germany 2,411 as in conversion test B; assets = liabilities + equity in every month, local amounts, Actual) | Pass |
| 3 | Rows and amounts by statement and currency (information) | - | e.g. balance sheet CAD 231,313,765.42 local = 150,238,103.07 USD; income statement EUR 16,854,017.33 local = 15,380,788.23 USD | - |
| 4 | Lineage | 0 rows without lineage, 1 batch | 0 / 1 | Pass |
| 5 | Empty staging is refused (D106, rolled back) | refused, 39,409, 39,409, 0 | As expected | Pass |
| 6 | Re-run | Succeeded, 39,409, 0 rows from other batches | As expected; 1 second | Pass |

Notes:
- The first run (batch 4057) failed one check: "balance sheet rows in May 2025" expected 0 (from D39),
  measured 6. The code was right; D39's evidence (dim finance check 3b) covered USD units only. The 6
  rows are equity reclassifications for France, Germany and Australia that net to 0 per unit. D39 was
  corrected, D115 added, and the check replaced by three checks; the second run passed.

---

## B5: Pipeline, data quality checks, security users and Agent job

**Script:** `tests/test_pipeline.sql` | **Run:** 2026-11-12 (batch 4078) | **Result:** 9 of 9 passed

| # | Test | Expected | Measured | Result |
|---|---|---|---|---|
| 1 | Definitions | 27 checks, 9 Error, 18 Warning; 4 users, 1 Executive, 3 Regional Managers | 27, 9, 18; 4, 1, 3 | Pass |
| 2 | A full run of `etl.run_pipeline` | Succeeded, 62 of 62 steps, 27 check results, 0 Fail, 0 Warn, no open transaction | As expected; 12 seconds | Pass |
| 3 | Every check result of that run | 27 rows, all Pass | 27 Pass. E01-E09 all 0; W05 64, W06 2,151, W07 7, W08 534, W11 342 as their baselines; W12 21.43%, W13 93.51% coverage; all other warnings 0 | Pass |
| 4 | Every fact comes from that run | Row counts as in B4a-B4d, 0 rows from other batches | sales 121,317; quota 163; work order 72,591; purchase 8,845; inventory 1,123; headcount 12,333; finance 39,409; 0 from other batches | Pass |
| 5 | Failure path 1: an Error check fails (E07 expected value made impossible, then restored) | Run fails, batch Failed, E07 Fail, check results and log kept, 0 rows from the failed batch, sales still from the good batch, E07 restored to 0 | failed, Failed, Fail, 27 results and 63 log rows kept (62 steps + rollback row), 0, 121,317, 0, no open transaction | Pass |
| 6 | Failure path 2: a step fails (territory map row pointing to a missing territory) | Run fails at `dim_organization` with the message kept, 0 rows from the failed batch, map restored | failed, Failed, dim_organization Failed, message kept, 1 check result (E01) kept, 0, 9 map rows, no open transaction | Pass |
| 7 | Staging count check stops the run (D100), rolled back | Stopped, 1 table differs, details name it, staging restored | stopped, 1, "stg.aw_shift source 3 staging 2", 3 rows after rollback | Pass |
| 8 | Security users (D71-D73, D117) | 3 checks PASS | 274 North America, 285 Pacific, 287 Europe; 0 users missing from `dim_employee`; 0 managers whose orders fall outside their region | Pass |
| 9 | Agent job definition (D78) | Enabled, 1 step `EXEC etl.run_pipeline;` in EnterpriseBI_DW, daily at 02:00 | As expected (freq_type 4, interval 1, start 020000) | Pass |

Notes:
- The first run of this test (batch 4063, 11 Nov 2026) passed every check except one warning:
  W03 measured 7 purchase lines shipped after their due date. A query showed all 7 were the 7 lines
  whose due date is before the order date (W07, D45). W03 now skips those lines (D119); this run
  measured 0.
- W08 is "at most 534": every Pending (477) and Approved (57) line held received goods at build.
- Real Agent run (11 Nov 2026): started with `sp_start_job`, job history "The job succeeded",
  step executed as `NT SERVICE\SQLSERVERAGENT`, 14 seconds; batch 4068 Succeeded in 13 seconds with
  `triggered_by` = `NT SERVICE\SQLSERVERAGENT`.
- Run times: 112 s (batch 4063) and 21 s (batch 4064) on 11 Nov 2026, 13 s (Agent), 12 s (this run).
  In the 112 s run the staging check step took 74 s; on its own it took 3 s. File autogrowth (about
  130 ms in total, default trace) and overlapping runs (batch times) were ruled out. The cause was
  not identified.
