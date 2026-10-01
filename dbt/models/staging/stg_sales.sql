-- One row per invoice line. Cleans and types the raw sales extract; no business rules yet
-- (line-type classification, consignment, returns all happen in intermediate).

select
    -- The extract has no line number and identical duplicate lines are legitimate,
    -- so the file + line position is the only unique key.
    _source_file || ':' || _source_line             as sales_line_id,
    '{{ var("company_id") }}'                       as company_id,

    {{ clean_text('Invoice_No') }}                  as invoice_no,
    {{ clean_text('Ord_ID') }}                      as order_id,
    {{ clean_text('BT_Cust_ID') }}                  as bill_to_customer_id,
    {{ clean_text('ST_Cust_ID') }}                  as ship_to_customer_id,

    {{ clean_text('Product_ID') }}                  as product_id,
    {{ clean_text('Product_Desc1') }}               as product_desc,
    {{ clean_text('Product_St') }}                  as product_status,
    {{ clean_text('Sell_Group') }}                  as sell_group,

    {{ clean_text('Out_Slsp') }}                    as outside_salesperson_id,
    {{ clean_text('In_Slsp') }}                     as inside_salesperson_id,
    {{ clean_text('Writer') }}                      as writer_id,

    {{ clean_text('Price_Br') }}                    as price_branch_id,
    {{ clean_text('Ship_Br') }}                     as ship_branch_id,
    {{ clean_text('ShipVia') }}                     as ship_via,
    {{ clean_text('Sls_Src') }}                     as sales_source,
    {{ clean_text('Order_St') }}                    as order_status,

    {{ to_date('Ship_Date') }}                      as ship_date,
    {{ to_date('Order_Date') }}                     as order_date,
    {{ to_date('Reqd_Date') }}                      as required_date,

    cast(Quantity as integer)                       as quantity,
    {{ to_amount('Ext_Price') }}                    as ext_price,
    {{ to_amount('Ext_Cost') }}                     as ext_cost,
    {{ to_amount('Ext_COGS') }}                     as ext_cogs,
    {{ to_amount('Ext_Prc_Chg') }}                  as ext_price_change,
    {{ to_amount('Ext_Wt') }}                       as ext_weight,

    -- Free-text customer PO. Also the only place consignment is labelled (used in intermediate).
    {{ clean_text('Cust_PO') }}                     as customer_po,

    -- Single-character markers in the source: present = yes.
    Direct is not null                              as is_direct_ship,
    Price_Ovr is not null                           as is_price_override,
    COGS_Ovr is not null                            as is_cogs_override,
    Cost_Ovr is not null                            as is_cost_override,
    Manual_Ovr = 'Y'                                as is_manual_override,
    {{ clean_text('Ovr_Sign') }}                    as override_sign,
    {{ clean_text('Cost_Flag') }}                   as cost_flag,
    {{ clean_text('Cost_Contract') }}               as cost_contract_id,
    {{ clean_text('Price_Flag') }}                  as price_flag,
    {{ clean_text('Price_Contract') }}              as price_contract_id,

    _source_file,
    cast(_source_line as integer)                   as _source_line,
    _loaded_at
from {{ source('raw', 'sales') }}
