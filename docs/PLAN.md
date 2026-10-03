# ADH Case Study: Final Plan (end to end)

## The story in one line
Raw ERP text files -> cleaned tables -> three business-ready tables (marts) -> a list of customers worth winning back -> a web app salespeople can use -> one extra tool that helps sales.

## 1. What the data actually is (profiled)

| File | What it is | Size / grain |
|---|---|---|
| sales_2023-2026 | Invoice **lines** (one row per product on an invoice) | 1.06M lines, 134K invoices, 1,033 ship-to customers, 11.6K products sold. Dates 2023-01-02 to 2026-09-08 |
| orders_2023-2026 | Invoice **headers** (one row per invoice) | 137.5K invoices; totals, freight, sales tax, salesperson |
| proddata | Product master | 1.11M rows = 159K SKUs x 7 branches (one row per SKU per branch) |
| custdata | Customer master | 4,170 customers (727 inactive) |
| invendata | Inventory snapshot as of 09/08/2026 | 26K rows, several per product |
| purch_2025/2026 | Purchase orders (what ADH buys from vendors) | ~27K rows each |
| branchdata, blinedata, gltypedata, slspdata | Small lookup tables (branches, brands, product types, salespeople) | tiny |

## 2. Data-quality problems found (these become talking points in the review)

1. **Mixed file encoding.** The files are not clean UTF-8 (they contain stray latin-1 bytes such as degree and registered-trademark symbols). Fix: a conversion step at ingestion.
2. **Consignment transfers (VALIDATED).** Consignment means ADH leaves stock with a contractor, who pays only for what they use and returns the rest. The data confirms it: ~376K transfer lines have $0 price and $0 cost, and their quantities net to almost exactly zero (+188K lines out, -189K back; net -4.9K units against 1.75M units moved), which is stock going out and coming back. The matching billing lines (~180K lines, $18.3M, ~16% of revenue) are priced normally and are real sales. Because transfers carry $0 price and $0 cost they do not distort revenue or gross profit, but counted as activity they would inflate units by ~75% and distort purchase frequency and last-purchase dates. There is no structured flag for consignment; the only label is free-text PO with many typos (CON T, CONS. TRANSFER, CONSINGMENT, CON TRASNFER...).
3. **Credits and returns** are negative-price lines (18.5K). They should be netted against sales and flagged.
4. **Ship-to vs bill-to.** In 47% of lines the ship-to customer differs from the bill-to customer. Decision needed on the "customer" grain (see section 4).
5. **Lines vs headers.** 132,753 invoices tie to the penny ($110.87M). Two groups do not: (a) 3,261 header-only invoices ($453K) with no product lines. These are real charges (service charges, fuel and handling surcharges, credits), so a lines-only model would miss them. (b) 1,527 invoices where line totals exceed the header by $794K net (0.7% of revenue), and in 1,521 of them the header counts one more line than the lines file contains, which points to lines missing from or added outside the extract. Decision: sales detail stays at line grain, header-only invoices are added as non-product rows so total revenue reconciles, and the 1,527 are flagged with a variance column. Root cause of (b) is unresolved and is listed as an open question.
6. **Duplicate lines are real, not errors.** 4,249 groups (4,478 extra rows) are identical in every column. Test: for the 933 invoices with priced duplicates, the total including the duplicates matches the header on 911; removing them matches on only 2. So the duplicates are legitimate repeat lines and must be kept. (The extract has no line-number column, which is why identical lines look like duplicates.) We keep them. (A `dup_count` flag was planned but dropped: no metric used it.)
7. **Product master is exploded by branch** (1.1M rows for 159K SKUs), so it needs collapsing to one row per SKU. 157 SKUs have a numeric GL_Type (e.g. "512", "491") instead of EQ/PA/IS/OT. This is not a column shift (every row has the correct field count). They are accounting/non-product entries: sales tax adjustments, service charges, returned check fees, web discounts, a loan payment, plus warranty plans, gift cards, promos and spiffs; the GL_Type holds an accounting code. None appear in sales or inventory. Decision: flag them as non-products in staging.
8. **Salesperson IDs are messy.** One person can have several IDs, and system IDs exist (WEB, ALL, HSE, LOGGED). About 250K lines have no outside salesperson. A mapping table cleans this up.
9. **Buy-line near-duplicates.** Only a few are safe to merge. Identical lookup descriptions (high confidence): STRMQU/STROM, AMERFITG/AMERIFIT, AMANA/AMA, LUCAS-MI/WOLVRN. Likely: FLANDERS/FLANSDER (descriptions differ, "Flanders Filters" vs "FLANDERS", but FLANSDER's description is the FLANDERS code and the code looks like a letter-swap typo). NOT typos and must stay separate: LUXRES vs LUXCOM (Luxaire residential vs commercial), STRMQU vs STRMLIT (Stromquist vs Streamlight). Uncertain: MTSUBIS vs MITSUBIS (both Mitsubishi, different lines). Approach: a small mapping table with a confidence column; only high-confidence rows are applied, and the raw buy line is always kept. Also 8 buy lines in the product master are missing from the lookup.
10. **Date coverage.** Sales and inventory both end 09/08/2026, so they are consistent. 2026 is a partial year (September has 8 days), so all "recent" windows are rolling periods from the latest date in the data, never hardcoded, and year-over-year comparisons use matching periods.
11. **Only about 11.6K of 159K SKUs have ever sold**, so "is it still actively sold and stocked" is a meaningful field.

## 3. Architecture (DuckDB + dbt + Streamlit)

```
data/raw/*.txt                  (supplied files, untouched)
   | 1. ingest.py               (convert encoding, load everything as text into DuckDB)
raw schema                      (exact copy of source)
   | 2. dbt staging models      (one per source: rename, type, trim, dedupe, flag bad rows)
staging schema
   | 3. dbt intermediate        (business rules: classify line type, map salespeople, pick customer grain)
   | 4. dbt marts               (the three required tables + supporting dimensions)
marts schema
   | 5. analysis (SQL/Python)   (opportunity scoring)
   | 6. Streamlit app           (ranked list, why flagged, customer drill-down)
   | 7. Part 4 extension        (win-back call sheet)
```

**Scaling to more operating companies:** every table carries a `company_id`; each company gets its own staging models that map into the same intermediate and mart columns, so marts and the app don't change when a company is added.

**Why this design (what Ayush says in the review):** each layer has one job, so a bug is easy to locate. Business rules (what counts as a sale) live in one place and are reused everywhere. To add another operating company, you add its own staging models that map into the same mart columns, and everything downstream keeps working.

**dbt tests:** unique and not-null keys, accepted values for line type, line totals tie to header totals within a tolerance, every sold product exists in the product master, every customer on a sale exists in the customer master.

## 4. The three required marts

| Mart | Grain | Key contents |
|---|---|---|
| `mart_sales_detail` | One row per invoice line, plus one non-product row per header-only invoice | Date, invoice, customer, branch, salesperson, SKU, category, brand; revenue, cost, gross profit, margin %, units; line type (sale / consignment billing / return-credit / no-charge / consignment transfer / stock transfer / payment record / header-only charge and adjustment types); is_financial and is_purchase flags; charge_amount and adjustment_amount; invoice reconciliation status; company_id |
| `mart_customers` | One row per customer | Name, branch, salesperson, type, active flag; first/last purchase date, days since last purchase, sales in last 12 months vs prior 12, lifetime sales and gross profit, invoice count, purchase frequency, average order value, categories bought |
| `mart_customer_years` *(added during build)* | One row per customer per calendar year | Full-year sales and gross profit (long-term trend across complete years) and same-period sales (Jan 1 to the as-of day, every year) to judge the unfinished year fairly; zeros included |
| `mart_products` | One row per SKU | Description, brand, product type (equipment/parts/supplies), cost and price, units and revenue (last 12 months, lifetime), last sold date, on-hand quantity, "active" flag (sold recently and/or stocked). Price and cost are observed from the last 12 months of sales (the product master has none) |
| `mart_inventory_by_branch` | One row per product per branch | Warehouse, available (warehouse minus committed), consignment and other stock; bin locations |

**Decision made (Customer grain):** the **bill-to** customer as the customer for opportunity analysis, because that is who pays and who the relationship belongs to, while keeping ship-to (job site or location) on the sales detail. Correction from earlier: consignment does NOT explain most of the ship-to/bill-to split (27% of ordinary priced sales still differ). The bigger cause is that one business often has several account IDs (for example 4 Seasons Heating & Air is ship-to 299 and bill-to 298), which makes bill-to the right grain even more clearly.

## 5. Part 2: how "opportunity" is defined

**Definition:** Opportunity = estimated gross profit dollars a customer *used to give us and no longer does*, weighted by how recoverable it is.

Steps:
1. Only real sales count (no consignment transfers or service charges).
2. For each customer, compare recent spend with their history using only like-for-like periods (a partial year is never compared with a full one):
   - **Long-term trend:** full calendar years (2023 -> 2024 -> 2025).
   - **This year so far:** the current year vs the same dates (Jan 1 to the as-of day) in earlier years; seasonality cancels out.
   - **Most recent full year:** last 12 months vs prior 12 (rolling from the latest date in the data).
   Combined: long-term decline + behind this year = strongest; long-term decline but on track = possibly recovering (lower); steady/growing but behind this year = early warning (modest, Q4 could recover); steady/growing and on track = no flag. Weighted by gross-profit dollars.
3. Flag customers whose recent spend dropped sharply, who have gone quiet longer than their normal buying rhythm, or who stopped buying categories they used to buy.
4. Estimated lost gross profit = (baseline - recent) x margin.
5. Recoverability adjustments: still buying something (good sign), has a consistent salesperson, recency of last purchase, etc.
6. Final priority score = lost gross profit x recoverability. Each row gets a plain-English reason ("Bought $4.2K/month through March, nothing since June; stopped buying refrigerant and copper fittings").

**Weaknesses to state openly:** seasonality (handled by comparing like-for-like periods only; a per-customer seasonal projection of the current year is deferred to next steps); we can't tell whether a customer left or simply had no projects; no competitor or win/loss data; consignment and ship-to handling affects customer history; the baseline window is a judgment call.

**Data that would help:** quote and lost-quote data, customer job pipeline, weather data, competitor pricing, contact history.

## 6. Part 3: the app (Streamlit)
- Ranked opportunity table with filters (branch, salesperson, minimum dollars).
- Click a customer to see "why flagged", key numbers, monthly sales trend, category mix (what they bought before vs now), and recent invoices.
- Export the filtered list to CSV for a salesperson.

## 7. Part 4: win-back call sheet
For each flagged customer, list the specific products they stopped buying, ranked by the profit they used to generate, with current stock on hand. A salesperson opens the app and sees exactly what to ask the customer about. It reuses the marts, adds a small amount of new logic, and is easy to explain.

## 8. Time budget (5 hours max)

| Phase | Hours |
|---|---|
| Ingest and staging (incl. encoding and cleanup) | 1.25 |
| Intermediate logic and the 3 marts + tests | 1.25 |
| Opportunity model | 0.75 |
| Streamlit app | 0.75 |
| Part 4 | 0.5 |
| README and review notes | 0.5 |

## 9. Deliverables (GitHub repo)
`README.md` (architecture, data model, assumptions, data-quality issues, methodology, Part 4 rationale, how to run, what's next), `ingest/`, `dbt/` project, `analysis/`, `app/`, `data/raw/` (gitignored because of size; README says where files go so the project is reproducible from the supplied source files), app screenshots, and `REVIEW_NOTES.md` (talking points for the 60-minute discussion). The application is delivered as a working app plus screenshots. Reviewers are not expected to run the code.

## 10. Risks
- The raw files are large and the reviewers already have them, so they stay out of the submission. The README documents where they go.
- Product category hierarchy may be thin (commodity and select-code fields looked blank in samples). Needs checking in the Products mart.
- A live follow-up change request will test how easily the model adapts (for example, a new definition of opportunity or a new operating company), which is why business rules live in one layer.

## 11. Decisions log (1-12 agreed with Ritu; 13+ made with Ayush during the build; 22-25 from ADH's answers)

| # | Decision | Notes |
|---|---|---|
| 1 | Gross profit uses `Ext_COGS`; keep `Ext_Cost` as a separate column | Compare the two in the data and revisit if needed. **Confirmed by ADH (2026-10-02).** |
| 2 | Header-only invoices are never product revenue. Split into two columns: `charge_amount` (service charges, fuel/handling surcharges, fees: +$869K) and `adjustment_amount` (rebates, AR adjustments, bad debt, prebuys, payment corrections, other credits: -$416K net); `line_type` keeps the detail | Revised with Ayush after profiling: only part of header-only is surcharges. Prebuys are customer deposits (a liability), not revenue; the goods are invoiced later as normal sales, so counting them would double count. How ADH applies the deposit (AR cash application) is not in the extract; to confirm |
| 3 | Returns and credits are netted against sales by default, with a flag to analyze them separately | |
| 4 | Transaction date = ship date. Keep order date and required date, plus an order-to-ship days field | Required date equals order date on 98% of lines, so it carries little information. Do not use it as a lateness measure |
| 5 | Customer mart uses the customer master's assigned salesperson; sales detail keeps both outside and inside salesperson | |
| 6 | Customer mart includes all customers (active, inactive, never purchased), with flags | Past purchasers who stopped buying are the Part 2 opportunity |
| 7 | "Active" SKU = sold in last 12 months (rolling from latest data date), plus a separate "currently stocked" flag | Revisit once product labeling is better understood |
| 8 | Product mart is one row per SKU; a separate branch-level inventory table keeps stock per branch | Lets a rep see which branch has an item (shipping-time use case) |
| 9 | Category hierarchy = product type (EQ/PA/IS/OT) -> brand (Buy_Line) -> sell group. No derived categories for now | Commodity and select-code fields are nearly empty (commodity filled for 74 of 11.6K sold SKUs). Derived keyword categories deferred as a possible later extension |
| 10 | App shows a product-type reference table (for example PA = Parts -> what it includes) | Idea from Ritu. Can later feed derived categories |
| 11 | Buy-line near-duplicates: keep a mapping table with confidence levels, apply only high-confidence pairs | Revisit while working with the data; a good challenge to discuss in the review |
| 12 | Consignment rule (validated): money logic uses price and cost, not text. A line is financial if price or cost is non-zero; $0/$0 lines are non-financial stock movements, excluded from units, frequency and last-purchase metrics but kept in the data. PO text is used only to label the type (consignment transfer / consignment billing / branch stock transfer / other), via a pattern list that tolerates typos | Robust because it does not depend on messy text; text only affects labels, never dollars |
| 13 | Staging models are tables, not views | Every cast runs at build time, so bad values fail in staging; later layers read typed data once. Cost: disk space and a few seconds |
| 14 | Identical duplicate lines are kept; no `dup_count` column | No metric used it. The evidence (header totals match with duplicates on 911 of 933 invoices) is documented in the model |
| 15 | Lines tie to the header within 1 cent | 377 invoices differ by exactly $0.01 (rounding). Gives 132,753 matched / 1,527 variance / 3,261 header-only |
| 16 | The bill-to on the invoice is the customer for transactions; names and attributes come from the customer master | 3 accounts are billed directly on invoices though the master says they bill elsewhere (tax-exempt twins); added to the customer mart (3,372 rows) |
| 17 | Reporting windows are defined once (`int_reporting_dates`), rolling from the latest ship date (2026-09-08) | Last 12 months = 2025-09-09 to 2026-09-08; prior 12 = the 12 months before. Start dates exclusive so no day is counted twice |
| 18 | Opportunity comparisons are like-for-like only: full calendar years, same period each year, rolling 12 vs prior 12 (see section 5) | Comparing partial 2026 with full 2025 turns +21% growth into -12%. Seasonal projection deferred (time budget) |
| 19 | Available stock = warehouse stock (stock_type S) minus committed; consignment stock at customer sites (C + customer ID) is shown separately | Summing all inventory rows would overstate what can ship. Warehouse stock can sit in several bins; all bins listed |
| 20 | Salesperson IDs with the same name (ignoring case) are one person, represented by the most-used ID; system accounts (HSE, WEB, ADMIN...) are a reviewable seed list | KEITH / KEITHS kept separate (names differ) |
| 21 | Product price and cost are observed: average unit price and COGS over the last 12 months of sales, plus inventory unit cost | The product master has no price or cost fields |
| 22 | Account ownership is by design: customers with no rep (smaller accounts) show as "No dedicated rep", HOUSE as "House account (executive team)" | Answered by ADH. Not a data-quality issue |
| 23 | Rebates and loyalty payouts are part of gross profit (a reduction of net sales); other header-only adjustments stay in `adjustment_amount` | Answered by ADH. Refines decision 2. -$735K gross profit; posts once a year (Dec 30-31), so comparisons stay fair |
| 24 | The invoice total is the source of truth: one correction row per variance invoice (header minus lines) | Answered by ADH. Replaces "keep lines, flag invoice" (decision 15). Lines overstate price by $794K with matching cost (likely a missing discount line); gross profit -$794K |
| 25 | Related bill-to accounts are one customer, via a reviewable seed (`customer_groups.csv`, 21 groups from name matches and the master's own links) | Answered by ADH. Refines decisions 16 and the customer grain. 3,349 customers; 4 accounts that were flagged alone are healthy once combined |
| 26 | `int_customer_transactions` is the single source of customer sales and gross profit (product lines + invoice corrections + rebates, rolled up to the customer group) | Keeps decisions 23-25 in one place; product-level views stay on product lines |

## 12. Open questions
**Answered by Andrew (ADH), 2026-10-02, and applied:**
- Account ownership: no salesperson / HOUSE is **by design** (smaller accounts get no rep; HOUSE = valued accounts handled by the executive team). Labels changed; scores unaffected (decision 22).
- `Ext_Cost` vs `Ext_COGS`: **COGS confirmed** (decision 1).
- Related bill-to accounts: **one customer** (decision 25).
- Rebates: **factored into gross profit** (decision 23).
- Invoices where lines exceed the header: **the invoice total is the source of truth** (decision 24).

Still open, to raise in the review:
- How prebuy deposits are applied (AR, not in the extract).
- Meaning of the small inventory stock types (F/R/T/L/Z).
- Biggs (customer 2829): 15,478 stock-transfer lines (WCTC/PCTC/SCTC STOCK TRANSFER) against 9,031 sales lines. A related company or stocking location rather than a contractor? Kept in the opportunity list ($414K real sales) until confirmed.
- Buy-line near-duplicates: the 4 high-confidence pairs are applied; still undecided are FLANSDER / FLANDERS (likely) and MTSUBIS / MITSUBIS (uncertain).
- Confirm with ADH that $0 consignment transfers + priced consignment billing is how they record consignment (data strongly supports it), and whether a structured consignment flag exists in the ERP that the extract left out.
