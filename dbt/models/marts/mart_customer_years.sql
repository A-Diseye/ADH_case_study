-- One row per customer per calendar year, for multi-year trends.
--   full_year_*     Jan 1 - Dec 31. The as-of year is incomplete (is_partial_year), so do not
--                   compare its full_year_* against complete years.
--   same_period_*   Jan 1 up to the as-of month/day (e.g. Jan 1 - Sep 8) in EVERY year. Both sides
--                   miss the same months, so seasonality cancels out: this is the fair way to judge
--                   whether the current, unfinished year is ahead or behind earlier years.
-- Every customer who has ever purchased gets a row for every year, including years with no sales
-- (0, not missing), so a drop to nothing shows up in the trend.

with dates as (
    select * from {{ ref('int_reporting_dates') }}
),

years as (
    select distinct year(ship_date) as sales_year
    from {{ ref('int_customer_transactions') }}
),

purchasers as (
    select distinct customer_id
    from {{ ref('int_customer_transactions') }}
    where is_purchase
),

yearly as (
    select
        s.customer_id,
        year(s.ship_date)                                                   as sales_year,
        sum(s.ext_price) filter (where s.is_financial)                      as full_year_sales,
        sum(s.gross_profit) filter (where s.is_financial)                   as full_year_gross_profit,
        count(distinct s.invoice_no) filter (where s.is_purchase)           as full_year_purchase_invoices,
        -- Same period: on or before the latest ship month and day
        sum(s.ext_price) filter (where s.is_financial
                                   and strftime(s.ship_date, '%m-%d') <= strftime(d.as_of_date, '%m-%d'))
                                                                            as same_period_sales,
        sum(s.gross_profit) filter (where s.is_financial
                                      and strftime(s.ship_date, '%m-%d') <= strftime(d.as_of_date, '%m-%d'))
                                                                            as same_period_gross_profit
    from {{ ref('int_customer_transactions') }} as s
    cross join dates as d
    group by s.customer_id, year(s.ship_date)
)

select
    c.customer_id || '-' || y.sales_year                            as customer_year_id,
    '{{ var("company_id") }}'                                               as company_id,
    c.customer_id,
    y.sales_year,
    y.sales_year = year(d.as_of_date)                                       as is_partial_year,
    'Jan 1 - ' || strftime(d.as_of_date, '%b %-d')                          as same_period_label,

    coalesce(v.full_year_sales, 0)                                          as full_year_sales,
    coalesce(v.full_year_gross_profit, 0)                                   as full_year_gross_profit,
    coalesce(v.full_year_purchase_invoices, 0)                              as full_year_purchase_invoices,
    coalesce(v.same_period_sales, 0)                                        as same_period_sales,
    coalesce(v.same_period_gross_profit, 0)                                 as same_period_gross_profit
from purchasers as c
cross join years as y
cross join dates as d
left join yearly as v
    on v.customer_id = c.customer_id
   and v.sales_year = y.sales_year
