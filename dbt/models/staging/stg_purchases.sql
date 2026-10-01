-- Purchase order lines (what we buy from vendors), 2025-2026.

select
    _source_file || ':' || _source_line             as purchase_line_id,
    '{{ var("company_id") }}'                       as company_id,
    {{ clean_text('PO_No') }}                       as po_no,
    {{ clean_text('Ord_ID') }}                      as order_id,
    {{ clean_text('SF_Ven_ID') }}                   as vendor_id,
    {{ clean_text('PT_Ven_ID') }}                   as pay_to_vendor_id,

    {{ clean_text('Product_ID') }}                  as product_id,
    {{ clean_text('Product_Desc1') }}               as product_desc,
    {{ clean_text('Product_St') }}                  as product_status,
    {{ clean_text('Buy_Grp') }}                     as buy_group,
    {{ clean_text('Buyer') }}                       as buyer_id,
    {{ clean_text('Writer') }}                      as writer_id,
    {{ clean_text('Order_Br') }}                    as order_branch_id,
    {{ clean_text('Receive_Br') }}                  as receive_branch_id,
    {{ clean_text('ShipVia') }}                     as ship_via,
    {{ clean_text('Order_Status') }}                as order_status,  -- only present in the 2026 file

    {{ to_date('Order_Date') }}                     as order_date,
    {{ to_date('Req_Date') }}                       as required_date,
    {{ to_date('Recv_Date') }}                      as received_date,

    cast(Quantity as integer)                       as quantity,
    {{ to_amount('Ext_COGP') }}                     as ext_purchase_cost,
    {{ to_amount('Ext_Wt') }}                       as ext_weight,

    _source_file,
    cast(_source_line as integer)                   as _source_line,
    _loaded_at
from {{ source('raw', 'purchases') }}
