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
