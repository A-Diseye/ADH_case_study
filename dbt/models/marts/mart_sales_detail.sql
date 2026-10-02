-- Sales detail: one row per invoice line, plus one non-product row per header-only invoice,
-- so totals reconcile to the invoice headers. Names and categories are joined in so the table
-- can be used on its own.
--
-- Money columns:
--   revenue / cogs / gross_profit   product lines only (0 on header-only rows)
--   charge_amount                   header-only charges (service charges, surcharges, fees)
--   adjustment_amount               header-only credits and prepayments (rebates, bad debt, prebuys...)
-- Filter is_financial for money totals and is_purchase for "did the customer buy something".

with product_lines as (
    select
        sales_line_id,
        company_id,
        'product_line'                  as row_source,
        invoice_no,
        ship_date,
        order_date,
        order_to_ship_days,
        bill_to_customer_id,
        ship_to_customer_id,
        outside_salesperson_id,
        inside_salesperson_id,
        price_branch_id,
        ship_branch_id,
        sales_source,
        customer_po,
        product_id,
        product_desc                    as line_product_desc,
        sell_group,
        line_type,
        is_financial,
        is_purchase,
        is_consignment,
        is_return_credit,
        quantity,
        ext_price                       as revenue,
        ext_cost                        as ext_cost,
        ext_cogs                        as cogs,
        gross_profit,
        0                               as charge_amount,
        0                               as adjustment_amount,
        _source_file,
        _source_line
    from {{ ref('int_sales_lines') }}
),

header_rows as (
    select
        sales_line_id,
        company_id,
        'header_only'                   as row_source,
        invoice_no,
        ship_date,
        null                            as order_date,
        null                            as order_to_ship_days,
        bill_to_customer_id,
        ship_to_customer_id,
        outside_salesperson_id,
        inside_salesperson_id,
        price_branch_id,
        ship_branch_id,
        sales_source,
        customer_po,
        null                            as product_id,
        null                            as line_product_desc,
        null                            as sell_group,
        line_type,
        is_financial,
        false                           as is_purchase,
        false                           as is_consignment,
        false                           as is_return_credit,
        null                            as quantity,
        0                               as revenue,
        0                               as ext_cost,
        0                               as cogs,
        0                               as gross_profit,
        charge_amount,
        adjustment_amount,
        _source_file,                   -- orders_*.txt (the header), not a sales file
        _source_line
    from {{ ref('int_header_only_entries') }}
),

all_rows as (
    select * from product_lines
    union all
    select * from header_rows
)

select
    r.sales_line_id,
    r.company_id,
    r.row_source,

    -- When
    r.ship_date,                                            -- transaction date
    r.order_date,
    r.order_to_ship_days,

    -- Invoice and its reconciliation to the header
    r.invoice_no,
    i.reconciliation_status,
    i.reconciliation_status = 'variance'                    as has_invoice_variance,

    -- Who
    r.bill_to_customer_id,
    bt.customer_name                                        as bill_to_customer_name,
    r.ship_to_customer_id,
    st.customer_name                                        as ship_to_customer_name,
    r.outside_salesperson_id,
    osp.person_name                                         as outside_salesperson,
    r.inside_salesperson_id,
    isp.person_name                                         as inside_salesperson,

    -- Where
    r.ship_branch_id,
    br.branch_name                                          as ship_branch_name,
    r.price_branch_id,
    r.sales_source,

    -- What (category hierarchy: product type -> brand -> sell group)
    r.product_id,
    coalesce(p.product_desc, r.line_product_desc)           as product_desc,
    p.gl_type                                               as product_type,
    p.gl_type_desc                                          as product_type_desc,
    p.mapped_buy_line                                       as brand,
    p.buy_line_desc                                         as brand_desc,
    r.sell_group,

    -- Classification
    r.line_type,
    r.is_financial,
    r.is_purchase,
    r.is_consignment,
    r.is_return_credit,

    -- Quantities and money
    r.quantity,
    case when r.is_financial then r.quantity else 0 end     as units,   -- $0 stock movements excluded
    r.revenue,
    r.cogs,
    r.gross_profit,
    r.gross_profit / nullif(r.revenue, 0)                   as margin_pct,
    r.ext_cost,                                             -- kept for reference; not used for profit
    r.charge_amount,
    r.adjustment_amount,

    r.customer_po,
    r._source_file,
    r._source_line
from all_rows as r
left join {{ ref('int_invoices') }} as i
    on i.invoice_no = r.invoice_no
left join {{ ref('stg_customers') }} as bt
    on bt.customer_id = r.bill_to_customer_id
left join {{ ref('stg_customers') }} as st
    on st.customer_id = r.ship_to_customer_id
left join {{ ref('int_salespeople') }} as osp
    on osp.salesperson_id = r.outside_salesperson_id
left join {{ ref('int_salespeople') }} as isp
    on isp.salesperson_id = r.inside_salesperson_id
left join {{ ref('stg_branches') }} as br
    on br.branch_id = r.ship_branch_id
left join {{ ref('int_products') }} as p
    on p.product_id = r.product_id
