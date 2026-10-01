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
2. **Consignment transfers look like sales.** Consignment means ADH leaves stock with a contractor, who pays only for what they use and returns the rest. About 40% of lines (420K of 1.06M) have a price of $0, and 227K have negative quantities. Customer PO text such as "CON.TRANSFER" and "CONS. BILLING" suggests the $0 lines are stock movements and the later billing lines are the real sales. Transfers are excluded from revenue and opportunity logic but kept in the data. Rule to be validated against the data before we build on it.
3. **Credits and returns** are negative-price lines (18.5K). They should be netted against sales and flagged.
4. **Ship-to vs bill-to.** In 47% of lines the ship-to customer differs from the bill-to customer. Decision needed on the "customer" grain (see section 4).
5. **Lines vs headers.** 132,753 invoices tie to the penny ($110.87M). Two groups do not: (a) 3,261 header-only invoices ($453K) with no product lines. These are real charges (service charges, fuel and handling surcharges, credits), so a lines-only model would miss them. (b) 1,527 invoices where line totals exceed the header by $794K net (0.7% of revenue), and in 1,521 of them the header counts one more line than the lines file contains, which points to lines missing from or added outside the extract. Decision: sales detail stays at line grain, header-only invoices are added as non-product rows so total revenue reconciles, and the 1,527 are flagged with a variance column. Root cause of (b) is unresolved and is listed as an open question.
6. **Duplicate lines are real, not errors.** 4,249 groups (4,478 extra rows) are identical in every column. Test: for the 933 invoices with priced duplicates, the total including the duplicates matches the header on 911; removing them matches on only 2. So the duplicates are legitimate repeat lines and must be kept. (The extract has no line-number column, which is why identical lines look like duplicates.) We keep them and add a `dup_count` flag.
7. **Product master is exploded by branch** (1.1M rows for 159K SKUs), so it needs collapsing to one row per SKU. Some rows also have misaligned columns (GL_Type contains numbers like "708" and "491"), likely from embedded tabs in text fields. These need detection and repair or quarantine.
8. **Salesperson IDs are messy.** One person can have several IDs, and system IDs exist (WEB, ALL, HSE, LOGGED). About 250K lines have no outside salesperson. A mapping table cleans this up.
9. **Buy-line near-duplicates.** Only a few are safe to merge. Identical lookup descriptions (high confidence): STRMQU/STROM, AMERFITG/AMERIFIT, AMANA/AMA, LUCAS-MI/WOLVRN. Likely (name match after normalizing case): FLANDERS/FLANSDER. NOT typos and must stay separate: LUXRES vs LUXCOM (Luxaire residential vs commercial), STRMQU vs STRMLIT (Stromquist vs Streamlight). Uncertain: MTSUBIS vs MITSUBIS (both Mitsubishi, different lines). Approach: a small mapping table with a confidence column; only high-confidence rows are applied, and the raw buy line is always kept. Also 8 buy lines in the product master are missing from the lookup.
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
| `mart_sales_detail` | One row per invoice line | Date, invoice, customer, branch, salesperson, SKU, category, brand; revenue, cost, gross profit, margin %, units; line type (sale / consignment billing / consignment transfer / return-credit / service charge / other $0); flag for whether it counts as a real sale; company_id |
| `mart_customers` | One row per customer | Name, branch, salesperson, type, active flag; first/last purchase date, days since last purchase, sales in last 12 months vs prior 12, lifetime sales and gross profit, invoice count, purchase frequency, average order value, categories bought |
| `mart_products` | One row per SKU | Description, brand, product type (equipment/parts/supplies), cost and price, units and revenue (last 12 months, lifetime), last sold date, on-hand quantity, "active" flag (sold recently and/or stocked) |

**Decision made (Customer grain):** the **bill-to** customer as the customer for opportunity analysis, because that is who pays and who the relationship belongs to, while keeping ship-to (job site or location) on the sales detail. Consignment billing is one reason ship-to and bill-to differ, so this also helps with that problem. I'll check the real split after consignment is labeled.

## 5. Part 2: how "opportunity" is defined

**Definition:** Opportunity = estimated gross profit dollars a customer *used to give us and no longer does*, weighted by how recoverable it is.

Steps:
1. Only real sales count (no consignment transfers or service charges).
2. For each active customer, compute their baseline (trailing run-rate before the decline) and their recent spend.
3. Flag customers whose recent spend dropped sharply, who have gone quiet longer than their normal buying rhythm, or who stopped buying categories they used to buy.
4. Estimated lost gross profit = (baseline - recent) x margin.
5. Recoverability adjustments: still buying something (good sign), has a consistent salesperson, recency of last purchase, etc.
6. Final priority score = lost gross profit x recoverability. Each row gets a plain-English reason ("Bought $4.2K/month through March, nothing since June; stopped buying refrigerant and copper fittings").

**Weaknesses to state openly:** seasonality (HVAC is seasonal, so we compare year-over-year where possible); we can't tell whether a customer left or simply had no projects; no competitor or win/loss data; consignment and ship-to handling affects customer history; the baseline window is a judgment call.

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

## 11. Decisions log (agreed with Ritu)

| # | Decision | Notes |
|---|---|---|
| 1 | Gross profit uses `Ext_COGS`; keep `Ext_Cost` as a separate column | Compare the two in the data and revisit if needed |
| 2 | Header-only surcharges (fuel, handling, service) go in a separate "charges" column, not product revenue | Expected to be roughly net-zero profit (pass-through of shipping/handling cost) |
| 3 | Returns and credits are netted against sales by default, with a flag to analyze them separately | |
| 4 | Transaction date = ship date. Keep order date and required date, plus an order-to-ship days field | Required date equals order date on 98% of lines, so it carries little information. Do not use it as a lateness measure |
| 5 | Customer mart uses the customer master's assigned salesperson; sales detail keeps both outside and inside salesperson | |
| 6 | Customer mart includes all customers (active, inactive, never purchased), with flags | Past purchasers who stopped buying are the Part 2 opportunity |
| 7 | "Active" SKU = sold in last 12 months (rolling from latest data date), plus a separate "currently stocked" flag | Revisit once product labeling is better understood |
| 8 | Product mart is one row per SKU; a separate branch-level inventory table keeps stock per branch | Lets a rep see which branch has an item (shipping-time use case) |
| 9 | Category hierarchy = product type (EQ/PA/IS/OT) -> brand (Buy_Line) -> sell group. No derived categories for now | Commodity and select-code fields are nearly empty (commodity filled for 74 of 11.6K sold SKUs). Derived keyword categories deferred as a possible later extension |
| 10 | App shows a product-type reference table (for example PA = Parts -> what it includes) | Idea from Ritu. Can later feed derived categories |
| 11 | Buy-line near-duplicates: keep a mapping table with confidence levels, apply only high-confidence pairs | Revisit while working with the data; a good challenge to discuss in the review |
| 12 | Consignment rule: test against the data first thing in the intermediate layer | Still open until validated |

## 12. Open questions to raise in the review
- Why 1,527 invoices have line totals above the header (header counts one more line than the lines file contains).
- Which buy-line near-duplicates are true duplicates.
- Whether the consignment inference matches how ADH actually records it.
- Product category data is sparse in the source.
