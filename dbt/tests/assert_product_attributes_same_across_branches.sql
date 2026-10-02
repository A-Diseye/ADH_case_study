-- int_products keeps one branch's row per SKU. That is only safe if descriptive attributes are
-- identical across branches. Returns any SKU where they differ (test fails if any rows).
select product_id
from {{ ref('stg_products') }}
group by product_id
having count(distinct coalesce(product_desc, '')) > 1
    or count(distinct coalesce(product_desc_2, '')) > 1
    or count(distinct coalesce(buy_line, '')) > 1
    or count(distinct coalesce(price_line, '')) > 1
    or count(distinct coalesce(gl_type, '')) > 1
    or count(distinct coalesce(product_status, '')) > 1
    or count(distinct coalesce(commodity_code, '')) > 1
    or count(distinct is_kit) > 1
