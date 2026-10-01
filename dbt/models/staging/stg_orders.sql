-- One row per invoice header. Header totals are what lines get reconciled against in intermediate.

select
    {{ clean_text('Invoice_No') }}                  as invoice_no,
    '{{ var("company_id") }}'                       as company_id,

    {{ clean_text('BT_Cust_ID') }}                  as bill_to_customer_id,
    {{ clean_text('ST_Cust_ID') }}                  as ship_to_customer_id,
    {{ clean_text('Out_Slsp') }}                    as outside_salesperson_id,
    {{ clean_text('In_Slsp') }}                     as inside_salesperson_id,
    {{ clean_text('Writer') }}                      as writer_id,
    {{ clean_text('PrBr') }}                        as price_branch_id,
    {{ clean_text('ShBr') }}                        as ship_branch_id,
    {{ clean_text('ShipVia') }}                     as ship_via,
    {{ clean_text('Sls_Src') }}                     as sales_source,
    {{ clean_text('Manifest') }}                    as manifest_no,
    {{ clean_text('Cust_PO') }}                     as customer_po,

    {{ to_date('Ship_Date') }}                      as ship_date,

    cast(Item_Cnt as integer)                       as item_count,
    {{ to_amount('Item_Total') }}                   as item_total,
    {{ to_amount('Cost_Total') }}                   as cost_total,
    {{ to_amount('COGS_Total') }}                   as cogs_total,
    {{ to_amount('Sales_Tax') }}                    as sales_tax,

    -- Freight and handling: billed to the customer vs expense to us, inbound vs outbound.
    {{ to_amount('Fght_Bill_In') }}                 as freight_billed_in,
    {{ to_amount('Fght_Bill_Out') }}                as freight_billed_out,
    {{ to_amount('Fght_Exp_In') }}                  as freight_expense_in,
    {{ to_amount('Fght_Exp_Out') }}                 as freight_expense_out,
    {{ to_amount('Hndl_Bill_In') }}                 as handling_billed_in,
    {{ to_amount('Hndl_Bill_Out') }}                as handling_billed_out,
    {{ to_amount('Hndl_Exp_In') }}                  as handling_expense_in,
    {{ to_amount('Hndl_Exp_Out') }}                 as handling_expense_out,

    _source_file,
    cast(_source_line as integer)                   as _source_line,
    _loaded_at
from {{ source('raw', 'orders') }}
