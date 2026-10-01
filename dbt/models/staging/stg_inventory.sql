-- Inventory snapshot (as of 09/08/2026). Several rows per product and branch, mostly one per bin location.

select
    _source_file || ':' || _source_line             as inventory_row_id,
    '{{ var("company_id") }}'                       as company_id,
    {{ clean_text('Product_ID') }}                  as product_id,
    {{ clean_text('Br') }}                          as branch_id,
    {{ clean_text('Location') }}                    as bin_location,
    {{ to_date('As_of_Date') }}                     as as_of_date,

    {{ clean_text('Buy_Line') }}                    as buy_line,
    {{ clean_text('Prc_Line') }}                    as price_line,
    {{ clean_text('GL_Type') }}                     as gl_type,
    {{ clean_text('Sell_Group') }}                  as sell_group,
    upper({{ clean_text('Prod_Commodity_Code') }})  as commodity_code,
    {{ clean_text('St') }}                          as product_status,
    {{ clean_text('Type') }}                        as stock_type,

    cast(Onhand_Qty as integer)                     as onhand_qty,
    cast(Committed as integer)                      as committed_qty,
    {{ to_amount('Ext_Cost') }}                     as ext_cost,
    {{ to_amount('Ext_COGS') }}                     as ext_cogs,
    {{ to_amount('Ext_Wt') }}                       as ext_weight,

    -- ERP demand statistics (meaning of PIL not documented).
    cast(PIL as integer)                            as pil,
    cast("DMD/mo" as decimal(18, 4))                as demand_per_month,
    cast("365_Day_Sales" as integer)                as sales_365_days,
    cast("365_Day_Hits" as integer)                 as hits_365_days,

    -- ABC-style ranking codes from the ERP.
    {{ clean_text('Rank1') }}                       as rank_1,
    {{ clean_text('Rank2') }}                       as rank_2,
    {{ clean_text('Rank3') }}                       as rank_3,
    {{ clean_text('Rank4') }}                       as rank_4,
    {{ clean_text('Rank5') }}                       as rank_5,

    _source_file,
    cast(_source_line as integer)                   as _source_line,
    _loaded_at
from {{ source('raw', 'inventory') }}
