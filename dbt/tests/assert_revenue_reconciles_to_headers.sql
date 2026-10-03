-- Every dollar must tie to the invoice headers, which ADH confirmed are the source of truth:
-- product lines + invoice corrections + header-only rows (charges, rebates, other adjustments)
-- = the sum of all invoice header totals. Nothing lost, nothing double counted.
-- Tolerance $1: 377 invoices differ from their header by exactly 1 cent (rounding; treated as
-- matched, no correction row), which nets to $0.49.
with detail as (
    select sum(ext_price) as amount
    from {{ ref('int_customer_transactions') }}
    where transaction_type in ('product_line', 'invoice_correction')
    union all
    select sum(charge_amount + adjustment_amount + rebate_amount) from {{ ref('int_header_only_entries') }}
),
headers as (
    select sum(header_item_total) as amount from {{ ref('int_invoices') }}
)
select (select sum(amount) from detail) as detail_total, (select amount from headers) as header_total
where abs((select sum(amount) from detail) - (select amount from headers)) > 1.00
