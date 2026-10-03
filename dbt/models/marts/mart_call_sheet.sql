-- Part 4: win-back call sheet. One row per customer per product they have mostly stopped buying
-- (worth opp_min_product_gp a year ago, down 80%+), with what a rep needs on the call:
-- what they used to buy and pay, our current typical price, and where we have it in stock.
-- "I saw you stopped buying X; we have 12 in Fayetteville, your home branch."

with stock as (
    select
        product_id,
        sum(available_qty)                                                  as available_all_branches,
        arg_max(branch_name, available_qty)                                 as best_branch,
        max(available_qty)                                                  as best_branch_available
    from {{ ref('mart_inventory_by_branch') }}
    group by product_id
)

select
    pc.customer_id || '-' || pc.product_id                                  as call_sheet_id,
    '{{ var("company_id") }}'                                               as company_id,
    pc.customer_id,
    pc.product_id,
    pr.product_desc,
    pr.product_type_desc,
    pc.brand,
    pc.brand_desc,
    row_number() over (partition by pc.customer_id order by pc.gp_prior_12m desc) as product_rank,

    -- What they used to buy vs now
    pc.gp_prior_12m,
    pc.gp_last_12m,
    pc.units_prior_12m,
    pc.units_last_12m,
    round(pc.units_prior_12m / 12.0, 1)                                     as avg_units_per_month_before,
    pc.last_purchase_date,
    pc.last_unit_price,                                                     -- what they last paid
    pr.avg_unit_price_last_12m                                              as current_typical_price, -- all customers, last 12m

    -- Can we ship it, and from where?
    coalesce(
        (select ib.available_qty from {{ ref('mart_inventory_by_branch') }} as ib
         where ib.product_id = pc.product_id and ib.branch_id = c.home_branch_id), 0)
                                                                            as available_home_branch,
    c.home_branch_name,
    coalesce(st.available_all_branches, 0)                                  as available_all_branches,
    case when coalesce(st.best_branch_available, 0) > 0 then st.best_branch end as best_branch,
    coalesce(st.best_branch_available, 0)                                   as best_branch_available
from {{ ref('int_customer_product_changes') }} as pc
join {{ ref('mart_customers') }} as c
    on c.customer_id = pc.customer_id
left join {{ ref('mart_products') }} as pr
    on pr.product_id = pc.product_id
left join stock as st
    on st.product_id = pc.product_id
where pc.is_mostly_stopped
