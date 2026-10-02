-- One row per SKU. The product master repeats every SKU once per branch (7 rows); all descriptive
-- attributes are identical across branches (checked by a test), so we keep the first branch's row.
-- Branch-level fields (buy_pack differs for 8 SKUs, target / target_type) are left out.

with one_row_per_sku as (
    select *
    from {{ ref('stg_products') }}
    qualify row_number() over (partition by product_id order by branch_id) = 1
)

select
    p.product_id,
    p.company_id,
    p.product_desc,
    p.product_desc_2,

    -- Category hierarchy (decision 9): product type -> brand (buy line) -> sell group (on sales lines)
    p.gl_type,
    g.gl_type_desc,
    p.buy_line,
    b.mapped_buy_line,
    b.buy_line_desc,
    p.price_line,

    p.is_non_product,
    p.product_status,
    p.commodity_code,
    p.select_code,
    p.is_kit,
    p.keywords,
    p.upc,
    p.mfr_catalog_no
from one_row_per_sku as p
left join {{ ref('stg_gltypes') }} as g
    on g.gl_type = p.gl_type
left join {{ ref('int_buylines') }} as b
    on b.buy_line = p.buy_line
