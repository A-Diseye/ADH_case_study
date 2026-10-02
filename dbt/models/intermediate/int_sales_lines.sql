-- One row per sales line, with the business rules applied:
--   * is_financial  : does the line carry money? (decided by price and COGS, never by text)
--   * line_type     : what kind of line it is (labels use the PO text only for naming)
--   * is_purchase   : does it count as the customer buying something (frequency, last purchase)?
-- Identical duplicate lines are deliberately NOT removed: they are legitimate repeat lines
-- (header totals match with them on 911 of 933 invoices, without them on only 2).

with lines as (
    select
        *,
        upper(coalesce(customer_po, '')) as po_upper
    from {{ ref('stg_sales') }}
),

flagged as (
    select
        *,

        -- Money rule (decision 12): a line is financial if price or COGS is non-zero.
        -- $0 / $0 lines are stock movements: kept, but not counted as sales activity.
        (ext_price <> 0 or ext_cogs <> 0) as is_financial,

        -- Consignment is only labelled in free-text PO, with many typos. Two patterns:
        --   1. a "consign" word, misspelt or not: CO + optional M/N + S + I/O/G
        --      (CONSIGNMENT, CONSINGMENT, COSIGNMENT, COMSIGNMENT...; excludes CONSTRUCTION, CONSULTING)
        --   2. known abbreviations as whole words: CON T, CONS. TRANSFER, CON/T, COS, CONTFER, ...
        (
            regexp_matches(po_upper, '\bCO[MN]?S[IOG][A-Z]*')
            or regexp_matches(po_upper, '\b(CON|CONS|CONT|COS|CONN|CONB|CONBILL|CONBILLING|CONTFER|CONTRASNFER|CONTRA?N?S?F?E?R?)\b')
        ) as is_consignment_text
    from lines
),

classified as (
    select
        *,
        case
            -- Non-financial ($0 price, $0 COGS): stock movements and records, not sales
            when not is_financial and is_consignment_text
                then 'consignment_transfer'   -- stock out to / back from a contractor's site
            when not is_financial and regexp_matches(upper(coalesce(product_desc, '')), '\bPAYMENT\b')
                then 'payment_record'         -- customer payments recorded on the "ONLINE PAYMENT" SKU
            when not is_financial and regexp_matches(po_upper, 'TRANSFER|TRANSFR|XFER|STOCK|RETURN|MOVE')
                then 'stock_transfer'         -- other stock moves (e.g. WCTC STOCK TRANSFER, RETURN TRANSFER)
            when not is_financial
                then 'other_zero_dollar'

            -- Financial lines
            when ext_price < 0
                then 'return_credit'          -- returns and credits: netted against sales, flagged
            when ext_price = 0
                then 'no_charge'              -- $0 price but real cost (free / warranty goods)
            when is_consignment_text
                then 'consignment_billing'    -- contractor billed for consignment stock they used
            else 'sale'
        end as line_type
    from flagged
)

select
    sales_line_id,
    company_id,
    invoice_no,
    order_id,
    bill_to_customer_id,
    ship_to_customer_id,
    product_id,
    product_desc,
    product_status,
    sell_group,
    outside_salesperson_id,
    inside_salesperson_id,
    writer_id,
    price_branch_id,
    ship_branch_id,
    ship_via,
    sales_source,

    ship_date,                                           -- transaction date for all analysis
    order_date,
    required_date,
    ship_date - order_date                               as order_to_ship_days,

    quantity,
    ext_price,
    ext_cost,
    ext_cogs,
    ext_price - ext_cogs                                 as gross_profit,
    ext_weight,
    customer_po,

    line_type,
    is_financial,
    is_consignment_text                                  as is_consignment,
    line_type = 'return_credit'                          as is_return_credit,
    -- Counts as the customer buying something: drives purchase frequency and last-purchase date.
    ext_price > 0                                        as is_purchase,

    is_direct_ship,
    is_price_override,
    is_cogs_override,
    is_cost_override,
    is_manual_override,
    price_contract_id,
    cost_contract_id,

    _source_file,
    _source_line
from classified
