-- On-hand stock per product per branch (snapshot as of 09/08/2026).
-- The snapshot has several rows per product and branch, one per stock bucket (stock_type):
--   S       our own warehouse stock, one row per bin (usually one bin; 874 product+branches use
--           several). Only one S row per product+branch carries the demand statistics.
--   C####   consignment stock sitting at customer #### (47 of 48 codes are customer IDs)
--   other   F / R / T / L / Z: small buckets, meaning not documented
-- For "which branch can ship this", only warehouse stock is available.

select
    product_id,
    branch_id,
    any_value(company_id)                                               as company_id,
    any_value(as_of_date)                                               as as_of_date,

    sum(onhand_qty) filter (where stock_type = 'S')                     as warehouse_qty,
    sum(onhand_qty) filter (where stock_type like 'C%')                 as consignment_qty,
    sum(onhand_qty) filter (where stock_type <> 'S' and stock_type not like 'C%')
                                                                        as other_qty,
    sum(onhand_qty)                                                     as total_onhand_qty,

    sum(ext_cogs) filter (where stock_type = 'S')                       as warehouse_value,
    sum(ext_cogs)                                                       as total_value,
    count(distinct stock_type) filter (where stock_type like 'C%')      as consignment_customer_count,

    -- Demand statistics only exist on the warehouse row
    max(committed_qty) filter (where stock_type = 'S')                  as committed_qty,
    max(demand_per_month) filter (where stock_type = 'S')               as demand_per_month,
    max(sales_365_days) filter (where stock_type = 'S')                 as sales_365_days,
    max(hits_365_days) filter (where stock_type = 'S')                  as hits_365_days,
    -- Shelf addresses in the warehouse. 874 product+branches are stored in more than one bin
    -- (up to 8), so list them all rather than pick one.
    string_agg(bin_location, ', ' order by bin_location) filter (where stock_type = 'S')
                                                                        as warehouse_bin_locations
from {{ ref('stg_inventory') }}
group by product_id, branch_id
