-- One row per customer per brand they bought in the last 24 months: gross profit in the prior
-- 12 months vs the last 12 months. Flags brands a customer has stopped buying.
-- Used for the "why flagged" reason in Part 2 and the win-back call sheet in Part 4.

with dates as (
    select * from {{ ref('int_reporting_dates') }}
)

select
    s.bill_to_customer_id                                                   as customer_id,
    p.mapped_buy_line                                                       as brand,
    any_value(p.buy_line_desc)                                              as brand_desc,

    sum(s.gross_profit) filter (where s.ship_date > d.prior_12m_start and s.ship_date <= d.last_12m_start)
                                                                            as gp_prior_12m,
    sum(s.gross_profit) filter (where s.ship_date > d.last_12m_start)       as gp_last_12m,
    max(s.ship_date) filter (where s.is_purchase)                           as last_purchase_date,

    -- Stopped buying: the brand mattered to them a year ago and they bought none of it since
    coalesce(sum(s.gross_profit) filter (where s.ship_date > d.prior_12m_start and s.ship_date <= d.last_12m_start), 0)
        >= {{ var('opp_min_brand_gp') }}
    and coalesce(sum(s.gross_profit) filter (where s.ship_date > d.last_12m_start), 0) <= 0
                                                                            as is_stopped
from {{ ref('int_sales_lines') }} as s
cross join dates as d
join {{ ref('int_products') }} as p
    on p.product_id = s.product_id
where s.is_financial
  and s.ship_date > d.prior_12m_start
  and p.mapped_buy_line is not null
group by s.bill_to_customer_id, p.mapped_buy_line
