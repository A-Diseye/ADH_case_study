# CLAUDE.md

Project guide for Claude Code. Read this first, then `docs/PLAN.md` (the full plan and the agreed decisions log).

## What this is
An interview case study for ADH (Advantage Distribution Holdings): turn raw ERP extracts from an HVAC distributor into an analytics foundation, find customers with lost sales to recapture, and build a simple app for salespeople.

Flow: raw ERP text files -> DuckDB raw -> dbt staging -> dbt intermediate -> dbt marts -> opportunity analysis -> Streamlit app.

**Current scope: Part 1 only** (ingest, staging, intermediate, the three marts, tests). Keep Parts 2-3 in mind when designing the marts, but don't build them yet.

## How to work with me
- I (Ayush) will present and defend this code in a 60-minute review. Understanding matters more than speed.
- Work **one layer at a time**: build it, run it, show me the output, and explain in plain English why each step exists. Wait for my go-ahead before the next layer.
- Follow the decisions log in `docs/PLAN.md` section 11. If something in the data contradicts a decision, stop and tell me; don't silently change it.
- Prefer simple, readable SQL over clever SQL. Comment the business rules, not the obvious syntax.
- Keep a running list of data-quality findings as you go. They go into the README.

## Stack
- Python 3 virtual env in `.venv/` (`source .venv/bin/activate`)
- DuckDB (local file database), dbt-duckdb, Streamlit, pandas
- Running on Ubuntu under WSL

## Data
- Raw files live in `data/raw/` and are **never committed** (too large; reviewers already have them). `data/` is gitignored.
- Files are tab-delimited with a header row and **not UTF-8**. Read as latin-1 / convert to UTF-8 at ingest. Use `quote=''`, since text fields can contain stray quote characters.
- Only load `*.txt` files. Ignore any `*:Zone.Identifier` files (Windows/WSL artifacts).
- Load everything as text (all varchar) in the raw layer; cast types in staging.

| File | Grain |
|---|---|
| `sales_2023-2026.txt` | Invoice line (one product on one invoice). ~1.06M rows |
| `orders_2023-2026.txt` | Invoice header (one row per invoice). ~137.5K rows |
| `proddata.txt` | Product x branch (159K SKUs x 7 branches). Collapse to one row per SKU |
| `custdata.txt` | Customer (4,170) |
| `invendata.txt` | Inventory snapshot as of 09/08/2026, several rows per product/branch |
| `purch_2025/2026.txt` | Purchase order lines |
| `branchdata`, `blinedata`, `gltypedata`, `slspdata` | Small lookups |

## Key business rules (see PLAN.md for the reasoning)
- **Customer = bill-to** (`BT_Cust_ID`). Keep ship-to on sales detail.
- **Consignment:** $0-price / $0-cost lines are stock movements, not sales. Classify lines by price and cost, never by text alone; PO text is only used to label the line type.
- **Gross profit = price - `Ext_COGS`.** Keep `Ext_Cost` as a separate column.
- **Returns/credits** (negative price) are netted against sales and flagged.
- **Header-only invoices** (surcharges, service charges, credits) are added as non-product rows so revenue reconciles. Invoices where lines and header disagree get a variance flag.
- **Identical duplicate lines are legitimate**. Keep them (verified against header totals).
- **Transaction date = ship date.** "Recent" windows are rolling from the latest date in the data, never hardcoded.
- Add a `company_id` column to every model so more operating companies can be added later.

## Conventions
- dbt layers: `staging/stg_<source>.sql`, `intermediate/int_<purpose>.sql`, `marts/mart_<name>.sql`.
- Every model gets a `schema.yml` entry with a description and key tests (unique, not_null, relationships, accepted_values).
- Small commits with clear messages after each working layer.
- Never commit `data/`, `.venv/`, `*.duckdb`, `target/`, `logs/`.
