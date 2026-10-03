-- One row per customer per brand: a roll-up of int_customer_product_changes (the 12-month windows
-- are calculated there, once). Flags brands a customer has mostly stopped buying.
-- Used for the "why flagged" reason in Part 2 and the brands table / call sheet in the app.

select
    customer_id,
    brand,
    any_value(brand_desc)                                                   as brand_desc,
    sum(gp_prior_12m)                                                       as gp_prior_12m,
    sum(gp_last_12m)                                                        as gp_last_12m,
    max(last_purchase_date)                                                 as last_purchase_date,

    -- Mostly stopped buying: the brand mattered to them a year ago and is down 80%+ since.
    -- Not "went to zero": a token order (e.g. $75K of a brand down to $562) must not hide the drop.
    sum(gp_prior_12m) >= {{ var('opp_min_brand_gp') }}
    and sum(gp_last_12m) <= (1 - {{ var('opp_brand_drop_pct') }}) * sum(gp_prior_12m)
                                                                            as is_mostly_stopped
from {{ ref('int_customer_product_changes') }}
where brand is not null
group by customer_id, brand
