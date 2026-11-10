# Business Questions

The questions the warehouse and the report are built to answer (D13). Every table exists to
answer at least one of them; `data_model.md` names the questions each fact answers.

**Source of this list.** The original Step 2.2 document was not kept. 24 questions (S1-S8,
F1-F4, H1-H5, P1-P7) come from saved screenshots of that list. Where the data checks or a later
decision changed a KPI, priority or wording (S2, S4, F2, H3, P1, P3, P7), the table shows the
current version and the notes quote the original. 7 questions
(S9, F5-F8, P8, P9) and the executive overview were rebuilt on 10 Nov 2026 from what the
repository already fixes for them (shown under "Evidence"), and confirmed by the project owner (D107).

**Columns.** *Priority* is the Step 2.2 priority (Must or Should); for rebuilt questions it was set
on 10 Nov 2026. *Changed by / notes* gives the reason for each change and quotes the original, so the change
stays visible.

---

## Sales

| # | Business question | KPIs | Priority | Changed by / notes |
|---|---|---|---|---|
| S1 | How much revenue are we making, and is it growing? | Revenue, Revenue YTD, YoY growth %, 3-month rolling average | Must | YTD and YoY use the sales module's own last data date (D24) |
| S2 | Which regions and territories perform best? | Revenue and gross margin % by group and territory | Must | Gross margin % added on 10 Nov 2026: reseller margin is 0.59% against 41.15% online (B4a test 4), so revenue alone can rank a territory wrongly. Originally: "Revenue by group and territory" |
| S3 | Which products and categories sell most, and which are most profitable? | Revenue, gross margin, margin % by category | Must | Cost rule D26 |
| S4 | How do online and reseller sales compare? | Revenue, orders and gross margin % by channel | Must | Gross margin % added on 10 Nov 2026: 41.15% online against 0.59% reseller (B4a test 4) is the largest difference between the channels. Originally: "Revenue and orders by channel" |
| S5 | Are salespeople meeting their targets? | Actual vs quota, % of quota (reseller orders only) | Must | Compared by quota period, not calendar quarter (D31) |
| S6 | How many orders and customers, and how big is an average order? | Orders, customers, average order value | Should | |
| S7 | Are we shipping on time? | Days to ship, % shipped by due date | Should | D18: kept as a hidden measure, because shipping always takes 7-8 days |
| S8 | How much discount are we giving? | Discount amount, discount % by offer | Should | D66 |
| S9 | Who are our best salespeople? | Revenue and % of quota reached, per salesperson | Must | Rebuilt. Evidence: D16 ("top performing salespeople", from revenue and quota attainment) |

## Finance

| # | Business question | KPIs | Priority | Changed by / notes |
|---|---|---|---|---|
| F1 | Are we on budget? | Actual vs budget, variance, variance % | Must | Budget exists May 2022 - April 2023 only (`limitations.md`) |
| F2 | How are revenue, expenses and net income trending? | Totals by account group over time; gross, operating and net margin % | Must | Margin % added on 10 Nov 2026: the brief asks for margin %, and the finance checks measured 67-70% gross, 25-28% operating, 19-22% net (D38). Signs from `sign_to_net_income` (D38). Originally: "Totals by account group over time" |
| F3 | Which organisation units (regions) perform best financially? | Net income by organisation | Must | No finance unit for the United Kingdom (`limitations.md`) |
| F4 | Where is money being spent? | Expenses by department group | Should | Corporate's own rows shown as "Corporate (direct)" (D35) |
| F5 | Do we have enough cash and short-term assets to pay our upcoming bills? | Current ratio over time, by organisation | Must | Rebuilt. Evidence: KPI "Current ratio" (`data_model.md` section 6); closing balances, latest month April 2025 (D39) |
| F6 | What do we own, what do we owe, and how is that changing? | Closing assets, liabilities and equity by month | Should | Rebuilt. Evidence: D39, D97; the USD balance sheet does not balance exactly (`limitations.md`) |
| F7 | What are the figures in each unit's own currency? | F2 totals in local currency, when one currency is selected | Should | Rebuilt. Evidence: D37 and `limitations.md` (local currency view, Should); local amount kept (D36) |
| F8 | Do the finance figures agree with the sales figures? | Finance net sales vs sales revenue, side by side, company level | Should | Rebuilt. Evidence: "F8 finding" in `fact_finance_checks.sql` (about 6% apart in total, not per organisation); never combined in one KPI (D40) |

## HR

| # | Business question | KPIs | Priority | Changed by / notes |
|---|---|---|---|---|
| H1 | How many people do we employ, and where? | Active headcount by department, shift | Must | Headcount is taken at a month-end, never summed over months (D57) |
| H2 | What does our workforce look like? | Split by gender, age band, salaried vs hourly | Must | Sensitive attributes in `dim_employee_hr` (D62); not visible to regional managers (D72) |
| H3 | How is hiring going, and how long have our people been with us? | Hires per year, average tenure | Must | Wording changed on 10 Nov 2026: the source has no termination dates and every employee is current (`limitations.md`), so only the tenure of current staff can be measured. Originally: "How is hiring going, and how long do people stay?" |
| H4 | What do we pay, by department? | Average pay rate (totals only, never per person) | Should | Complementary suppression (D64) |
| H5 | How much leave is outstanding? | Vacation and sick hours by department | Should | Answered from `dim_employee_hr` (current values), not from the headcount fact |

## Supply chain

| # | Business question | KPIs | Priority | Changed by / notes |
|---|---|---|---|---|
| P1 | How much are we spending, and with which vendors? | Purchase spend (accepted goods value, all order statuses), by vendor and category | Must | **D42:** Pending and Approved orders already hold received goods. Originally: "Purchase spend (Complete orders), by vendor and category" |
| P2 | How many purchase orders are stuck or rejected? | Count and value of Pending, Approved, Rejected | Must | |
| P3 | Are vendors delivering good quality? | OTIF % (main), unit fill rate, rejected quantity %, by vendor | Must | **D43:** OTIF varies (89.3%) while on-time alone is always 100%. Originally: "Rejected quantity %, by vendor" |
| P4 | Do we have enough stock? | Current stock vs safety stock and reorder point | Must | Stock status D51 |
| P5 | How is our stock level changing over time? | Stock units and stock value trend | Should | **D49, D54:** not built; the DW stock history is unreliable. Listed as an open item |
| P6 | How much production is wasted, and why? | Scrap rate %, scrap by reason | Must | Scrap rate is the main KPI (D46) |
| P7 | Is production finishing on time? | % of work orders finished by due date | Must | **D47:** 31.4% of work orders finish late. Originally: priority Should |
| P8 | Which products do we need to reorder now? | Products below their reorder point, counting stock plus open purchase orders | Must | Rebuilt. Evidence: inventory check 5 ("stock limits (P4, P8)"); reorder logic with open purchase quantity (D51, D52) |
| P9 | How many days of sales does our stock cover? | Stock on hand divided by average daily units sold, per product | Should | Rebuilt. Evidence: `data_model.md` (P9 answered by `fact_sales` and `fact_inventory_current`) |

## Executive overview

| # | Business question | KPIs | Priority | Changed by / notes |
|---|---|---|---|---|
| E | How is the company doing overall, at a glance? | One headline KPI per module (revenue, net income, headcount, OTIF), plus revenue per employee | Must | Rebuilt. Evidence: brief step 5 (executive pages with KPIs); KPI "Revenue per employee" (`data_model.md` section 6) |
