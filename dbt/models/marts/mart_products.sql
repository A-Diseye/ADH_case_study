-- Products: one row per SKU (all 159K in the master, including never-sold and non-products, flagged).
--   * The product master has no price or cost, so price and cost here are what we actually
--     sold at and paid, over the last 12 months (from sales lines), plus the inventory unit cost.
--   * Units and revenue net returns; $0 stock movements are excluded (is_financial).
--   * Active (decision 7) = sold in the last 12 months, rolling from the latest date in the data.
--     "Currently stocked" is a separate flag: warehouse stock on hand in any branch.
--   * Stock per branch is in mart_inventory_by_branch (decision 8).

with dates as (
    select * from {{ ref('int_reporting_dates') }}
),

sales as (
    select
        s.product_id,
        max(s.ship_date) filter (where s.is_purchase)                       as last_sold_date,
        min(s.ship_date) filter (where s.is_purchase)                       as first_sold_date,

        sum(s.quantity) filter (where s.is_financial and s.ship_date > d.last_12m_start)
                                                                            as units_last_12m,
        sum(s.ext_price) filter (where s.is_financial and s.ship_date > d.last_12m_start)
                                                                            as revenue_last_12m,
        sum(s.gross_profit) filter (where s.is_financial and s.ship_date > d.last_12m_start)
                                                                            as gross_profit_last_12m,
        count(distinct s.bill_to_customer_id) filter (where s.is_purchase and s.ship_date > d.last_12m_start)
                                                                            as customers_last_12m,

        sum(s.quantity) filter (where s.is_financial)                       as lifetime_units,
        sum(s.ext_price) filter (where s.is_financial)                      as lifetime_revenue,
        sum(s.gross_profit) filter (where s.is_financial)                   as lifetime_gross_profit,

        -- Observed unit price and cost: positive-price lines in the last 12 months
        sum(s.ext_price) filter (where s.is_purchase and s.ship_date > d.last_12m_start)
            / nullif(sum(s.quantity) filter (where s.is_purchase and s.ship_date > d.last_12m_start), 0)
                                                                            as avg_unit_price_last_12m,
        sum(s.ext_cogs) filter (where s.is_purchase and s.ship_date > d.last_12m_start)
            / nullif(sum(s.quantity) filter (where s.is_purchase and s.ship_date > d.last_12m_start), 0)
                                                                            as avg_unit_cogs_last_12m,

        -- Third category level. 35 SKUs have more than one sell group on their lines: take the most common.
        mode(s.sell_group)                                                  as sell_group
    from {{ ref('int_sales_lines') }} as s
    cross join dates as d
    group by s.product_id
),

stock as (
    select
        product_id,
        sum(warehouse_qty)                                                  as warehouse_qty,
        sum(consignment_qty)                                                as consignment_qty,
        sum(warehouse_value)                                                as warehouse_value,
        count(*) filter (where warehouse_qty > 0)                           as branches_with_stock
    from {{ ref('int_inventory_by_branch') }}
    group by product_id
)

select
    p.product_id,
    p.company_id,
    p.product_desc,
    p.product_desc_2,

    -- Category hierarchy (decision 9): product type -> brand -> sell group
    p.gl_type                                                   as product_type,
    p.gl_type_desc                                              as product_type_desc,
    p.mapped_buy_line                                           as brand,
    p.buy_line_desc                                             as brand_desc,
    p.buy_line                                                  as raw_buy_line,
    s.sell_group,

    p.is_non_product,
    p.product_status,
    p.is_kit,
    p.mfr_catalog_no,
    p.upc,

    -- Price and cost (observed)
    s.avg_unit_price_last_12m,
    s.avg_unit_cogs_last_12m,
    st.warehouse_value / nullif(st.warehouse_qty, 0)            as inventory_unit_cost,

    -- Sales
    s.first_sold_date,
    s.last_sold_date,
    d.as_of_date - s.last_sold_date                             as days_since_last_sold,
    coalesce(s.units_last_12m, 0)                               as units_last_12m,
    coalesce(s.revenue_last_12m, 0)                             as revenue_last_12m,
    coalesce(s.gross_profit_last_12m, 0)                        as gross_profit_last_12m,
    coalesce(s.customers_last_12m, 0)                           as customers_last_12m,
    coalesce(s.lifetime_units, 0)                               as lifetime_units,
    coalesce(s.lifetime_revenue, 0)                             as lifetime_revenue,
    coalesce(s.lifetime_gross_profit, 0)                        as lifetime_gross_profit,
    s.lifetime_gross_profit / nullif(s.lifetime_revenue, 0)     as lifetime_margin_pct,

    -- Stock (as of the inventory snapshot)
    coalesce(st.warehouse_qty, 0)                               as warehouse_qty,
    coalesce(st.consignment_qty, 0)                             as consignment_qty,
    coalesce(st.branches_with_stock, 0)                         as branches_with_stock,

    -- Flags (decision 7)
    coalesce(s.last_sold_date > d.last_12m_start, false)        as is_active,
    coalesce(st.warehouse_qty, 0) > 0                           as is_currently_stocked,

    d.as_of_date
from {{ ref('int_products') }} as p
cross join dates as d
left join sales as s
    on s.product_id = p.product_id
left join stock as st
    on st.product_id = p.product_id
