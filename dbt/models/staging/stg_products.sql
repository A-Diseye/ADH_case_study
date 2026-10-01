-- One row per SKU per branch (the source repeats each SKU for all 7 branches).
-- Collapsing to one row per SKU happens in intermediate.
-- Dropped: UD1-UD10 (user-defined fields with no documented meaning; UD4 just repeats the SKU),
-- and columns that are empty in every row (SECONDARY_UPCS, SELL_PACK).

with gl_types as (
    select gl_type from {{ ref('stg_gltypes') }}
)

select
    {{ clean_text('Product_ID') }} || '-' || {{ clean_text('BRANCH') }}  as product_branch_id,
    '{{ var("company_id") }}'                       as company_id,
    {{ clean_text('Product_ID') }}                  as product_id,
    {{ clean_text('BRANCH') }}                      as branch_id,

    {{ clean_text('Product_Desc1') }}               as product_desc,
    {{ clean_text('Product_Desc2') }}               as product_desc_2,
    {{ clean_text('Buy_Line') }}                    as buy_line,
    {{ clean_text('Prc_Line') }}                    as price_line,
    {{ clean_text('GL_Type') }}                     as gl_type,

    -- Real products have a GL type from the lookup (EQ/PA/IS/OT). The rest are accounting
    -- entries (tax adjustments, service charges, fees, gift cards, warranties...) whose GL_Type
    -- holds an accounting code, plus one blank-type test SKU. None of them appear in sales.
    coalesce({{ clean_text('GL_Type') }} not in (select gl_type from gl_types), true)
                                                    as is_non_product,

    {{ clean_text('St') }}                          as product_status,
    {{ clean_text('Product_Select_Code') }}         as select_code,
    upper({{ clean_text('Prod_Commodity_Code') }})  as commodity_code,
    Kit is not null                                 as is_kit,
    {{ clean_text('Keywords') }}                    as keywords,
    {{ clean_text('UPC') }}                         as upc,
    {{ clean_text('MFR_CAT_NO') }}                  as mfr_catalog_no,
    {{ clean_text('RELATED_PRODUCTS') }}            as related_products,
    cast(BUY_PACK as integer)                       as buy_pack,
    {{ clean_text('TARGET_TYPE') }}                 as target_type,
    cast(TARGET as integer)                         as target,

    _source_file,
    cast(_source_line as integer)                   as _source_line,
    _loaded_at
from {{ source('raw', 'products') }}
