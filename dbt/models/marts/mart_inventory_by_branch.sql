-- Stock by product and branch (decision 8): lets a rep see which branch has an item.
-- Only warehouse stock can ship; consignment stock sits at customer sites and is shown separately.

select
    i.product_id || '-' || i.branch_id                          as product_branch_id,
    i.company_id,
    i.product_id,
    p.product_desc,
    p.gl_type_desc                                              as product_type_desc,
    p.mapped_buy_line                                           as brand,
    i.branch_id,
    b.branch_name,
    i.as_of_date,

    coalesce(i.warehouse_qty, 0)                                as warehouse_qty,
    coalesce(i.consignment_qty, 0)                              as consignment_qty,
    coalesce(i.other_qty, 0)                                    as other_qty,
    i.committed_qty,
    -- What a rep could actually promise: warehouse stock not already committed to orders
    coalesce(i.warehouse_qty, 0) - coalesce(i.committed_qty, 0) as available_qty,
    i.warehouse_value,
    i.warehouse_bin_locations,
    i.consignment_customer_count,

    i.demand_per_month,
    i.sales_365_days                                            as erp_units_sold_365_days,
    i.hits_365_days                                             as erp_order_hits_365_days
from {{ ref('int_inventory_by_branch') }} as i
left join {{ ref('int_products') }} as p
    on p.product_id = i.product_id
left join {{ ref('stg_branches') }} as b
    on b.branch_id = i.branch_id
