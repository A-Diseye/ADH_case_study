-- Everything that counts towards a customer's sales and gross profit, in one place:
--   product_line        every sales line (as int_sales_lines)
--   invoice_correction  one row per invoice whose lines disagree with the header. ADH confirmed the
--                       invoice total is the source of truth, so this row is header minus lines. The
--                       lines overstate price but not cost (likely a missing discount/credit line).
--   rebate              loyalty / ICP rebates. ADH confirmed they belong in gross profit. Treated as a
--                       reduction of net sales (as accounting does), so gross profit = sales - COGS holds.
-- Customer-level marts read this model; product-level views stay on product lines.

with product_lines as (
    select
        sales_line_id                       as transaction_id,
        company_id,
        bill_to_customer_id,
        invoice_no,
        ship_date,
        'product_line'                      as transaction_type,
        product_id,
        ext_price,
        ext_cogs,
        gross_profit,
        is_financial,
        is_purchase,
        is_return_credit,
        is_consignment
    from {{ ref('int_sales_lines') }}
),

invoice_corrections as (
    select
        invoice_no || ':correction'         as transaction_id,
        company_id,
        bill_to_customer_id,
        invoice_no,
        ship_date,
        'invoice_correction'                as transaction_type,
        null                                as product_id,
        header_item_total - line_price_total                                    as ext_price,
        header_cogs_total - line_cogs_total                                     as ext_cogs,
        (header_item_total - line_price_total) - (header_cogs_total - line_cogs_total) as gross_profit,
        true                                as is_financial,
        false                               as is_purchase,
        false                               as is_return_credit,
        false                               as is_consignment
    from {{ ref('int_invoices') }}
    where reconciliation_status = 'variance'
),

rebates as (
    select
        sales_line_id                       as transaction_id,
        company_id,
        bill_to_customer_id,
        invoice_no,
        ship_date,
        'rebate'                            as transaction_type,
        null                                as product_id,
        rebate_amount                       as ext_price,
        0                                   as ext_cogs,
        rebate_amount                       as gross_profit,
        true                                as is_financial,
        false                               as is_purchase,
        false                               as is_return_credit,
        false                               as is_consignment
    from {{ ref('int_header_only_entries') }}
    where line_type = 'rebate_loyalty'
),

all_transactions as (
    select * from product_lines
    union all
    select * from invoice_corrections
    union all
    select * from rebates
)

-- customer_id is the customer for analysis: the bill-to account rolled up to its customer group
-- (related accounts are one customer, confirmed by ADH)
select
    t.*,
    coalesce(g.customer_id, t.bill_to_customer_id)          as customer_id
from all_transactions as t
left join {{ ref('int_customer_groups') }} as g
    on g.account_id = t.bill_to_customer_id
