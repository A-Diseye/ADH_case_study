-- Line revenue + header-only entries (charges + adjustments) must equal header totals plus the known line variance.
-- Proves that adding header-only invoices closes the gap, and nothing is lost or double counted.
with detail as (
    select sum(ext_price) as amount from {{ ref('int_sales_lines') }}
    union all
    select sum(charge_amount + adjustment_amount) from {{ ref('int_header_only_entries') }}
),
headers as (
    select sum(header_item_total) + sum(coalesce(line_variance, 0)) as amount
    from {{ ref('int_invoices') }}
)
select (select sum(amount) from detail) as detail_total, (select amount from headers) as header_total
where abs((select sum(amount) from detail) - (select amount from headers)) > 0.01
