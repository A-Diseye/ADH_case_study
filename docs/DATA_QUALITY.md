# Data-quality findings (running log)

Collected layer by layer. These feed the README and the review talking points.

## Ingest

| # | Finding | Impact | Handling |
|---|---|---|---|
| 1 | **Mixed encoding, even within one file.** Most non-ASCII lines are latin-1 (`®`, `°` in product descriptions), but `custdata.txt` and a few order/sales lines are UTF-8. | Reading everything as latin-1 would garble the UTF-8 lines (`Rosè` -> `RosÃ¨`). | Each line is decoded as UTF-8 first, then latin-1 if that fails. 4,948 lines needed latin-1 (sales 2,675, products 2,142, purchases 127, orders 4). |
| 2 | **Some names were already garbled at the source** (double-encoded). Example: customer 9112 is stored as the bytes for `RosÃ¨` and 8779 as `DanÃ¢ÂÂs`; the ERP saved UTF-8 text as if it were latin-1. About 5 customers plus a few orders. | Cosmetic (customer names only). | Kept as-is in raw; repaired in staging (see #8). |
| 3 | **Stray quote characters are everywhere** (244K sales lines contain `"`, used for inches, e.g. `36" DUCT TIE`). | A normal CSV reader would treat `"` as a quote and merge or split fields. | Loaded with quoting turned off (`quote=''`). |
| 4 | **Every row has the right number of fields** (checked in all files). | No embedded tabs, so nothing is shifted. | None needed. |
| 4a | **157 "products" are accounting entries, not products.** Their GL_Type holds an accounting code number (`512`, `491`, ...) instead of EQ/PA/IS/OT: sales tax adjustments, service charges, returned check fees, web discounts, a loan payment, warranty plans, gift cards, promos/spiffs. None appear in sales or inventory. (Earlier assumption that this was a column shift was wrong.) | Would pollute product counts and the product-type breakdown. | Flag as non-product in staging (`is_non_product`), keep the raw GL code. |
| 5 | **Purchase files differ in shape:** `purch_2026` has an extra `Order_Status` column. | | Files combined by column name; `Order_Status` is NULL for 2025. |
| 6 | **Files are split by year** (sales, orders, purchases), one product file has a stray name (`proddata -.txt`), and the sales files also come as `.zip` duplicates. | | Yearly files stacked into one table; only `*.txt` loaded; `_source_file` and `_source_line` kept on every row for lineage. |
| 7 | **Sales have no line-number column.** | Identical duplicate lines can't be told apart by any business key. | `_source_file` + `_source_line` gives every raw row a unique key. |

## Staging

| # | Finding | Impact | Handling |
|---|---|---|---|
| 8 | **Only 3 garbled-text patterns exist** (`’` `á` `è`, double-encoded by the ERP), plus non-breaking spaces and 2 null bytes. Affects 4 customer names, 1 address and a handful of PO texts. | Names like `DanÃ¢ÂÂs` would show in the app. | `clean_text` macro repairs them (`Dan's`, `Rosè`). Applied to every text column. |
| 9 | **Whitespace and blanks:** 200K product descriptions have trailing spaces; 3,484 sales lines have an inside salesperson of just spaces. | Joins and group-bys would treat `'X '` and `'X'` differently; blank IDs would look like a real salesperson. | Every text column trimmed; blank -> NULL. |
| 10 | **All numbers and dates parse cleanly.** Quantities are whole numbers everywhere; prices have at most 2 decimals. | | Casts are strict, so a bad value in a future extract fails the build instead of becoming NULL. |
| 11 | **Referential integrity is clean** for sales: every bill-to, ship-to, product and invoice on a line exists in its master. Same for inventory and purchase products. | | Enforced as dbt relationship tests. |
| 12 | **Customer `Inactive` flag** is 1 (727), 0 (275) or blank (3,168). | | Blank treated as active -> 727 inactive. |
| 13 | **Salesperson `JAMESD`** is assigned to 2 customers but not in the salesperson lookup. | Those 2 customers would show no salesperson name. | dbt warning; handle in the salesperson mapping (intermediate). |
| 14 | **8 buy lines on products are missing from the buy-line lookup** (OBSOLETE 13 SKUs, REED 8, PREMDUCT 4, TECUMSE 3, TASCO 3, RESCON/JUGLUG/CARSONM 1 each). | No brand description for 34 SKUs. | dbt warning; brand falls back to the code. |
| 15 | **The 157 non-products** = 156 accounting entries + 1 test SKU (`99871 ECLIPSETEST 24 GRILL`, blank GL type). | | `is_non_product` = GL type not in the lookup (or blank). Data-driven, not a hardcoded list. |
| 16 | **$0 price / $0 COGS lines: 419,611**, more than the ~376K consignment transfers in the plan. | The ~43K difference should be branch transfers and other $0 lines. | To be confirmed when line types are classified in intermediate. |
| 17 | **Two cost columns: `Ext_Cost` vs `Ext_COGS`.** On priced lines Cost is $94.1M vs COGS $87.6M (Cost > COGS on 90% of lines). Checked against vendor purchase costs (same product, same month, 23,785 pairs): unit COGS / purchase cost has median **1.00** (83% within 5%); unit Cost / purchase cost has median **1.06** (16% within 5%). Cost is often a fixed per-unit value (e.g. R407C cylinder always $427.90) while COGS moves with purchase prices. | Margin is 27.9% using COGS vs 22.6% using Cost ($6.5M difference). | Supports decision #1: gross profit = price - COGS (COGS tracks real inventory cost). `Ext_Cost` looks like a standard / commission cost; kept as a separate column. Meaning to confirm with ADH. |
