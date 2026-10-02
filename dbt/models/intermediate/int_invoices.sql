-- One row per invoice header, with its lines summed up and compared to the header totals.
-- reconciliation_status:
--   matched      line prices sum to the header item total (within 1 cent of rounding)
--   variance     they disagree (mostly the header counts one more line than the extract has)
--   header_only  the header has no lines at all (service charges, surcharges, credits)

with line_totals as (
    select
        invoice_no,
        count(*)            as line_count,
        sum(ext_price)      as line_price_total,
        sum(ext_cogs)       as line_cogs_total
    from {{ ref('int_sales_lines') }}
    group by invoice_no
)

select
    o.invoice_no,
    o.company_id,
    o.bill_to_customer_id,
    o.ship_to_customer_id,
    o.outside_salesperson_id,
    o.inside_salesperson_id,
    o.price_branch_id,
    o.ship_branch_id,
    o.sales_source,
    o.customer_po,
    o.ship_date,

    o.item_count                                        as header_item_count,
    o.item_total                                        as header_item_total,
    o.cogs_total                                        as header_cogs_total,
    o.sales_tax,
    o.freight_billed_out,
    o.handling_billed_out,

    coalesce(l.line_count, 0)                           as line_count,
    l.line_price_total,
    l.line_cogs_total,
    l.line_price_total - o.item_total                   as line_variance,

    case
        when l.invoice_no is null                       then 'header_only'
        when abs(l.line_price_total - o.item_total) <= 0.01 then 'matched'
        else 'variance'
    end                                                 as reconciliation_status,

    o._source_file,                                     -- the header's row in orders_*.txt
    o._source_line
from {{ ref('stg_orders') }} as o
left join line_totals as l
    on l.invoice_no = o.invoice_no
