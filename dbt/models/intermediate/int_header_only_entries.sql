-- Header-only invoices (a header with no product lines) reshaped as one non-product row each,
-- so they can be added to sales detail and total revenue reconciles to the headers.
-- None of them is a product sale, and they are two different kinds of money, so they go in
-- two separate columns (never in product revenue):
--   charge_amount      real charges to the customer: service charges, surcharges, fees
--   adjustment_amount  credits and prepayments: rebates, AR adjustments, bad debt, prebuys,
--                      payment corrections and other one-off credits
-- line_type keeps the finer detail. The PO text and sales source only choose the label and
-- column; the amount always comes from the header.

with header_only as (
    select
        *,
        upper(coalesce(customer_po, '')) as po_upper
    from {{ ref('int_invoices') }}
    where reconciliation_status = 'header_only'
),

labelled as (
    select
        *,
        case
            when header_item_total = 0
                then 'other_zero_dollar'

            -- Charges
            when sales_source = 'SR' or regexp_matches(po_upper, 'SERV\w*\s*CH')
                then 'service_charge'
            when regexp_matches(po_upper, 'SURCHARGE|\bFEE\b|FREIGHT|HANDLING')
                then 'surcharge_fee'

            -- Adjustments
            when regexp_matches(po_upper, 'PRE\W*BUY|PRE\W*PA?Y|PREPMT|DEPOSIT')
                then 'prebuy_prepayment'      -- customer pays up front; the goods are invoiced later as normal sales
            when regexp_matches(po_upper, 'REBATE|LOYAL|SPIF|PROPERKS|ICP')
                then 'rebate_loyalty'
            when regexp_matches(po_upper, 'BAD\W*DEBT|WRITE\W*OFF')
                then 'bad_debt'
            when regexp_matches(po_upper, 'AR\W*ADJ|\bADJ')
                then 'ar_adjustment'
            when regexp_matches(po_upper, '\bACH\b|\bCHE?C?K\b|PAYMENT|\bPMT\b')
                then 'payment_correction'     -- returned ACH / returned checks
            else 'other_adjustment'           -- room credits, dealer meeting, donations, billboards, corrections
        end as line_type
    from header_only
)

select
    invoice_no || ':header'                             as sales_line_id,
    company_id,
    invoice_no,
    bill_to_customer_id,
    ship_to_customer_id,
    outside_salesperson_id,
    inside_salesperson_id,
    price_branch_id,
    ship_branch_id,
    sales_source,
    customer_po,
    ship_date,

    line_type,
    case when line_type in ('service_charge', 'surcharge_fee') then 'charge'
         when line_type = 'other_zero_dollar' then 'zero_dollar'
         else 'adjustment'
    end                                                 as entry_group,

    case when line_type in ('service_charge', 'surcharge_fee')
         then header_item_total else 0 end              as charge_amount,
    case when line_type not in ('service_charge', 'surcharge_fee', 'other_zero_dollar')
         then header_item_total else 0 end              as adjustment_amount,
    header_cogs_total                                   as header_cogs,       -- $0 on every header-only invoice

    header_item_total <> 0                              as is_financial
from labelled
