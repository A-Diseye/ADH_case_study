-- One row per customer per product bought in the last 24 months: gross profit, units and price in
-- the prior 12 months vs the last 12 months. The window logic lives here once; brand-level drops
-- (int_customer_brand_changes) are a roll-up of this model.
-- is_mostly_stopped: the product mattered to them a year ago (opp_min_product_gp) and is down
-- opp_brand_drop_pct (80%) or more since. Feeds the Part 4 call sheet.

with dates as (
    select * from {{ ref('int_reporting_dates') }}
),

windows as (
    select
        t.customer_id,                                                       -- customer group
        s.product_id,
        sum(s.gross_profit) filter (where s.ship_date <= d.last_12m_start)  as gp_prior_12m,
        sum(s.gross_profit) filter (where s.ship_date >  d.last_12m_start)  as gp_last_12m,
        sum(s.quantity)     filter (where s.ship_date <= d.last_12m_start)  as units_prior_12m,
        sum(s.quantity)     filter (where s.ship_date >  d.last_12m_start)  as units_last_12m,
        max(s.ship_date)    filter (where s.is_purchase)                    as last_purchase_date,
        -- Unit price on their most recent purchase of this product
        arg_max(s.ext_price / s.quantity, s.ship_date) filter (where s.is_purchase and s.quantity > 0)
                                                                            as last_unit_price
    from {{ ref('int_customer_transactions') }} as t
    join {{ ref('int_sales_lines') }} as s
        on s.sales_line_id = t.transaction_id                               -- product lines only
    cross join dates as d
    where s.is_financial
      and s.ship_date > d.prior_12m_start
    group by t.customer_id, s.product_id
)

select
    w.customer_id,
    w.product_id,
    p.mapped_buy_line                                                       as brand,
    p.buy_line_desc                                                         as brand_desc,
    coalesce(w.gp_prior_12m, 0)                                             as gp_prior_12m,
    coalesce(w.gp_last_12m, 0)                                              as gp_last_12m,
    coalesce(w.units_prior_12m, 0)                                          as units_prior_12m,
    coalesce(w.units_last_12m, 0)                                           as units_last_12m,
    w.last_purchase_date,
    w.last_unit_price,
    coalesce(w.gp_prior_12m, 0) >= {{ var('opp_min_product_gp') }}
        and coalesce(w.gp_last_12m, 0) <= (1 - {{ var('opp_brand_drop_pct') }}) * coalesce(w.gp_prior_12m, 0)
                                                                            as is_mostly_stopped
from windows as w
join {{ ref('int_products') }} as p
    on p.product_id = w.product_id
