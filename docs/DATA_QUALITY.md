# Data-quality findings (running log)

Collected layer by layer. These feed the README and the review talking points.

## Ingest

| # | Finding | Impact | Handling |
|---|---|---|---|
| 1 | **Mixed encoding, even within one file.** Most non-ASCII lines are latin-1 (`®`, `°` in product descriptions), but `custdata.txt` and a few order/sales lines are UTF-8. | Reading everything as latin-1 would garble the UTF-8 lines (`Rosè` -> `RosÃ¨`). | Each line is decoded as UTF-8 first, then latin-1 if that fails. 4,948 lines needed latin-1 (sales 2,675, products 2,142, purchases 127, orders 4). |
| 2 | **Some names were already garbled at the source** (double-encoded). Example: customer 9112 is stored as the bytes for `RosÃ¨` and 8779 as `DanÃ¢ÂÂs`; the ERP saved UTF-8 text as if it were latin-1. About 5 customers plus a few orders. | Cosmetic (customer names only). | Kept as-is in raw. Can be repaired in staging (re-encode latin-1 -> decode UTF-8) if worth it. |
| 3 | **Stray quote characters are everywhere** (244K sales lines contain `"`, used for inches, e.g. `36" DUCT TIE`). | A normal CSV reader would treat `"` as a quote and merge or split fields. | Loaded with quoting turned off (`quote=''`). |
| 4 | **Every row has the right number of fields** (checked in all files). | No embedded tabs, so nothing is shifted. | None needed. |
| 4a | **157 "products" are accounting entries, not products.** Their GL_Type holds an accounting code number (`512`, `491`, ...) instead of EQ/PA/IS/OT: sales tax adjustments, service charges, returned check fees, web discounts, a loan payment, warranty plans, gift cards, promos/spiffs. None appear in sales or inventory. (Earlier assumption that this was a column shift was wrong.) | Would pollute product counts and the product-type breakdown. | Flag as non-product in staging (`is_non_product`), keep the raw GL code. |
| 5 | **Purchase files differ in shape:** `purch_2026` has an extra `Order_Status` column. | | Files combined by column name; `Order_Status` is NULL for 2025. |
| 6 | **Files are split by year** (sales, orders, purchases), one product file has a stray name (`proddata -.txt`), and the sales files also come as `.zip` duplicates. | | Yearly files stacked into one table; only `*.txt` loaded; `_source_file` and `_source_line` kept on every row for lineage. |
| 7 | **Sales have no line-number column.** | Identical duplicate lines can't be told apart by any business key. | `_source_file` + `_source_line` gives every raw row a unique key. |
