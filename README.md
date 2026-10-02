# ADH Case Study: HVAC Distributor Analytics

Turns raw ERP extracts from an HVAC distributor into an analytics foundation, identifies customers with lost sales worth recapturing, and gives salespeople a simple app to act on it.

> **Status:** Part 1 in progress. Ingest and staging are built and tested; intermediate and marts are next. Sections for Parts 2-4 describe the planned approach.

---

## Architecture

```
data/raw/*.txt            supplied ERP extracts (not committed)
   │  ingest/ingest.py    fix encoding, load everything as text
   ▼
raw schema                faithful copy of the source + lineage columns
   │  dbt staging         one model per source: rename, type, trim, blank -> NULL
   ▼
staging schema
   │  dbt intermediate    business rules: line types, consignment, header reconciliation, mappings
   ▼
intermediate schema
   │  dbt marts           the three business-ready tables
   ▼
marts schema  ──►  opportunity analysis  ──►  Streamlit app
```

**Stack:** Python, DuckDB (local file database), dbt-duckdb, Streamlit.

### Design decisions

- **Each layer has one job.** Ingest only makes the files loadable, staging only cleans one source at a time, intermediate holds the business rules, and marts present results. When a number looks wrong, the layer tells you where to look: a bad date is a staging problem; a consignment line counted as a sale is an intermediate problem.
- **Business rules are written once.** Rules such as "what counts as a sale" live in intermediate and are reused by every mart and by the app.
- **Raw is a faithful copy.** Everything loads as text; types are cast in staging. Ingest adds `_source_file` and `_source_line` to every row so any value can be traced back to the original file line.
- **Staging is materialized as tables, not views.**
  - *Fail early, in the right layer:* every cast runs at build time, so a bad value in any column stops the build at staging instead of surfacing later in whichever model first reads that column.
  - *Faster downstream:* intermediate reads the sales lines several times; with a table the trimming, text repair and casting on 1M+ rows happens once, not on every read.
  - *Faster filtering:* DuckDB keeps min/max statistics on stored typed columns, so date-window filters (e.g. last 12 months) skip whole blocks of rows.
  - *Cost:* some disk space and a few seconds of build time. Tables never go stale because every data load is followed by `dbt build`.
- **Strict parsing.** Dates and numbers are cast strictly, so a format change in a future extract fails the build instead of silently becoming NULL.
- **Built for more operating companies.** Every model carries a `company_id`. A new company gets its own staging models that map into the same columns; intermediate, marts and the app do not change.

## Data model

| Layer | Models | Grain |
|---|---|---|
| Staging | `stg_sales` | Invoice line (1.06M) |
| | `stg_orders` | Invoice header (137.5K) |
| | `stg_customers` | Customer account (4,170) |
| | `stg_products` | SKU x branch (1.11M = 159K SKUs x 7 branches) |
| | `stg_inventory` | Product x branch x bin location (snapshot 09/08/2026) |
| | `stg_purchases` | Purchase order line |
| | `stg_branches`, `stg_buylines`, `stg_gltypes`, `stg_salespeople` | Lookups |
| Marts *(planned)* | `mart_sales_detail` | Invoice line, plus header-only charges as non-product rows |
| | `mart_customers` | Bill-to customer |
| | `mart_products` | SKU (with a separate branch-level inventory table) |

## Important assumptions

- **Customer = bill-to** (who pays and owns the relationship). Ship-to is kept on sales detail; one business often has several ship-to accounts.
- **Gross profit = price - `Ext_COGS`.** COGS matches vendor purchase cost (median ratio 1.00 against PO costs); `Ext_Cost` runs ~6% higher and looks like a standard/commission cost. Both are kept.
- **Consignment is classified by money, not text.** Lines with $0 price and $0 cost are stock movements, kept in the data but excluded from units, frequency and last-purchase metrics. The free-text PO field is only used to label line types.
- **Returns and credits** (negative price) are netted against sales and flagged.
- **Identical duplicate lines are legitimate** (verified against invoice header totals) and are kept.
- **Transaction date = ship date.** "Recent" windows roll back from the latest date in the data, never hardcoded.
- **Blank `Inactive` flag = active customer** (gives 727 inactive).
- **Non-products:** 157 SKUs whose product type is not EQ/PA/IS/OT (accounting entries and one test SKU) are flagged, not deleted.

## Data-quality issues

Full running log with numbers: [docs/DATA_QUALITY.md](docs/DATA_QUALITY.md). Highlights:

1. **Mixed encoding**, even within one file (latin-1 and UTF-8). Decoded line by line: UTF-8 first, latin-1 fallback.
2. **Text garbled by the ERP itself** (e.g. `RosÃ¨` for `Rosè`). Repaired in staging.
3. **Quote characters used for inches** in 244K lines. Loaded with quoting disabled.
4. **No line number on sales lines**, and identical duplicates are real. File + line position is used as the key.
5. **Product master repeated per branch**, and 157 "products" are accounting entries (tax adjustments, fees, gift cards, warranties).
6. **Consignment has no structured flag**, only free-text PO with many typos.
7. **Invoice lines vs headers:** header-only invoices (surcharges, service charges) and ~1.5K invoices where lines and header disagree.
8. **Lookups are incomplete:** one salesperson ID and 8 buy lines are missing from their lookups (reported as dbt warnings).
9. **Two cost columns** with different meanings (see assumptions).

## Opportunity methodology *(Part 2, planned)*

**Opportunity = estimated gross profit a customer used to give us and no longer does, weighted by how recoverable it is.**

1. Count real sales only (no consignment transfers or service charges).
2. For each customer, compare a baseline run-rate with recent spend, year over year where possible to respect HVAC seasonality.
3. Flag sharp drops, customers quiet for longer than their normal buying rhythm, and categories they stopped buying.
4. Lost gross profit = (baseline - recent) x margin.
5. Weight by recoverability signals (still buying something, consistent salesperson, recency).
6. Each flagged customer gets a plain-English reason.

## Part 4: win-back call sheet *(planned)*

For each flagged customer, list the specific products they stopped buying, ranked by the profit they used to generate, with current stock on hand by branch. A salesperson opens the app and knows exactly what to ask about and whether it can ship today. It reuses the marts with little new logic, and it turns a score into a concrete conversation.

## How to run

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 1. Put the supplied ERP .txt files anywhere under data/raw/
# 2. Load them into DuckDB (data/adh.duckdb)
python ingest/ingest.py

# 3. Build and test the dbt models
cd dbt && dbt build
```

## Next steps with more time

- Confirm open questions with ADH: the meaning of `Ext_Cost`, why ~1.5K invoices have lines that exceed the header, and whether a structured consignment flag exists in the ERP.
- Derived product categories from descriptions/keywords (the source category fields are nearly empty).
- Salesperson and buy-line mapping tables reviewed with the business.
- Incremental loads instead of full reloads, and scheduled runs.
