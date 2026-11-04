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
