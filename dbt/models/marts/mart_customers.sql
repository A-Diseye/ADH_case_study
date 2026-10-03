-- Customers: one row per customer = BILL-TO account, with related bill-to accounts (tax / non-tax,
-- install / service, duplicates) rolled up into one customer, as confirmed by ADH (customer_groups).
-- Includes every bill-to customer: active, inactive and never purchased (decision 6).
--   * The bill-to recorded on the invoice is the customer for transactions. Three accounts are used
--     as bill-to on invoices although the master says they bill elsewhere, so they are added too.
--   * Names and attributes come from the bill-to account's own row in the customer master.
--   * Salesperson = the master's assigned salesperson (decision 5).
-- Sales and gross profit come from int_customer_transactions: product lines, plus invoice corrections
-- (the invoice total is the source of truth) and rebates (part of gross profit), as confirmed by ADH.
-- Revenue nets returns; "purchase" dates and frequency use product lines with a positive price.
-- Header-only charges and other adjustments are separate columns.
-- Windows roll back from the latest ship date in the data (int_reporting_dates).

with dates as (
    select * from {{ ref('int_reporting_dates') }}
),

groups as (
    select * from {{ ref('int_customer_groups') }}
),

bill_to_customers as (
    select g.customer_id as bill_to_customer_id
    from {{ ref('stg_customers') }} as c join groups as g on g.account_id = c.bill_to_customer_id
    union
    select customer_id from {{ ref('int_customer_transactions') }}
    union
    select g.customer_id
    from {{ ref('int_header_only_entries') }} as h join groups as g on g.account_id = h.bill_to_customer_id
),

-- Bill-to accounts that make up each customer (more than one for related accounts)
accounts as (
    select customer_id, string_agg(account_id, ', ' order by account_id) as account_ids
    from groups
    where customer_id in (select customer_id from groups where grouping_reason is not null)
    group by customer_id
),

ship_to_accounts as (
    select g.customer_id as bill_to_customer_id, count(*) as ship_to_account_count
    from {{ ref('stg_customers') }} as c
    join groups as g on g.account_id = c.bill_to_customer_id
    group by g.customer_id
),

sales as (
    select
        s.customer_id                                                       as bill_to_customer_id,

        min(s.ship_date) filter (where s.is_purchase)                       as first_purchase_date,
        max(s.ship_date) filter (where s.is_purchase)                       as last_purchase_date,

        sum(s.ext_price) filter (where s.is_financial)                      as lifetime_sales,
        sum(s.gross_profit) filter (where s.is_financial)                   as lifetime_gross_profit,
        sum(s.ext_price) filter (where s.is_financial and s.ship_date > d.last_12m_start)
                                                                            as sales_last_12m,
        sum(s.gross_profit) filter (where s.is_financial and s.ship_date > d.last_12m_start)
                                                                            as gross_profit_last_12m,
        sum(s.ext_price) filter (where s.is_financial and s.ship_date > d.prior_12m_start
                                                      and s.ship_date <= d.last_12m_start)
                                                                            as sales_prior_12m,
        sum(s.gross_profit) filter (where s.is_financial and s.ship_date > d.prior_12m_start
                                                         and s.ship_date <= d.last_12m_start)
                                                                            as gross_profit_prior_12m,
        sum(s.ext_price) filter (where s.is_return_credit)                  as lifetime_returns,

        count(distinct s.invoice_no) filter (where s.is_purchase)           as purchase_invoice_count,
        count(distinct s.ship_date) filter (where s.is_purchase)            as purchase_day_count,
        count(distinct s.invoice_no) filter (where s.is_purchase and s.ship_date > d.last_12m_start)
                                                                            as purchase_invoices_last_12m,

        -- Category mix: product types and brands bought
        string_agg(distinct p.gl_type_desc, ', ' order by p.gl_type_desc) filter (where s.is_purchase)
                                                                            as product_types_bought,
        count(distinct p.mapped_buy_line) filter (where s.is_purchase)      as brands_bought_count,

        bool_or(s.is_consignment and s.is_financial)                        as has_consignment_billing
    from {{ ref('int_customer_transactions') }} as s
    cross join dates as d
    left join {{ ref('int_products') }} as p
        on p.product_id = s.product_id
    group by s.customer_id
),

header_only as (
    select
        g.customer_id                       as bill_to_customer_id,
        sum(charge_amount)      as lifetime_charges,
        sum(adjustment_amount)  as lifetime_adjustments,
        sum(rebate_amount)      as lifetime_rebates
    from {{ ref('int_header_only_entries') }} as h
    join groups as g on g.account_id = h.bill_to_customer_id
    group by g.customer_id
)

select
    b.bill_to_customer_id                                       as customer_id,
    coalesce(acc.account_ids, b.bill_to_customer_id)            as account_ids,
    c.company_id,
    c.customer_name,
    c.city,
    c.state,
    c.phone,
    c.email,
    c.customer_type,
    c.customer_class,
    c.home_branch_id,
    br.branch_name                                              as home_branch_name,
    c.salesperson_id,
    sp.person_name                                              as salesperson_name,
    coalesce(sp.is_system_account, false)                       as is_house_account,
    c.is_inactive,
    coalesce(a.ship_to_account_count, 0)                        as ship_to_account_count,

    -- Status, for filtering and for Part 2
    case
        when s.first_purchase_date is null                      then 'never_purchased'
        when s.last_purchase_date > d.last_12m_start            then 'active_last_12m'
        else 'lapsed'
    end                                                         as purchase_status,

    -- Recency
    s.first_purchase_date,
    s.last_purchase_date,
    d.as_of_date - s.last_purchase_date                         as days_since_last_purchase,

    -- Last 12 months vs the 12 months before
    coalesce(s.sales_last_12m, 0)                               as sales_last_12m,
    coalesce(s.sales_prior_12m, 0)                              as sales_prior_12m,
    coalesce(s.sales_last_12m, 0) - coalesce(s.sales_prior_12m, 0)
                                                                as sales_change_12m,
    (coalesce(s.sales_last_12m, 0) - s.sales_prior_12m) / nullif(s.sales_prior_12m, 0)
                                                                as sales_change_12m_pct,
    coalesce(s.gross_profit_last_12m, 0)                        as gross_profit_last_12m,
    coalesce(s.gross_profit_prior_12m, 0)                       as gross_profit_prior_12m,

    -- Lifetime (whole data period, 2023-01 to as_of_date)
    coalesce(s.lifetime_sales, 0)                               as lifetime_sales,
    coalesce(s.lifetime_gross_profit, 0)                        as lifetime_gross_profit,
    s.lifetime_gross_profit / nullif(s.lifetime_sales, 0)       as lifetime_margin_pct,
    coalesce(s.lifetime_returns, 0)                             as lifetime_returns,

    -- Buying rhythm
    coalesce(s.purchase_invoice_count, 0)                       as purchase_invoice_count,
    coalesce(s.purchase_invoices_last_12m, 0)                   as purchase_invoices_last_12m,
    -- Average gap between days with a purchase: the customer's normal rhythm
    (s.last_purchase_date - s.first_purchase_date) / nullif(s.purchase_day_count - 1, 0)
                                                                as avg_days_between_purchases,
    s.lifetime_sales / nullif(s.purchase_invoice_count, 0)      as avg_order_value,

    -- What they buy
    s.product_types_bought,
    coalesce(s.brands_bought_count, 0)                          as brands_bought_count,
    coalesce(s.has_consignment_billing, false)                  as has_consignment_billing,

    -- Header-only money, kept separate from sales
    coalesce(h.lifetime_charges, 0)                             as lifetime_charges,
    coalesce(h.lifetime_adjustments, 0)                         as lifetime_adjustments,
    coalesce(h.lifetime_rebates, 0)                             as lifetime_rebates,           -- already inside sales and gross profit

    d.as_of_date
from bill_to_customers as b
cross join dates as d
left join {{ ref('stg_customers') }} as c
    on c.customer_id = b.bill_to_customer_id
left join sales as s
    on s.bill_to_customer_id = b.bill_to_customer_id
left join accounts as acc
    on acc.customer_id = b.bill_to_customer_id
left join header_only as h
    on h.bill_to_customer_id = b.bill_to_customer_id
left join ship_to_accounts as a
    on a.bill_to_customer_id = b.bill_to_customer_id
left join {{ ref('int_salespeople') }} as sp
    on sp.salesperson_id = c.salesperson_id
left join {{ ref('stg_branches') }} as br
    on br.branch_id = c.home_branch_id
