-- The marts must not lose or duplicate money through their joins:
--   1. sales detail has exactly one row per sales line + one per header-only invoice + one per correction
--   2. sales detail revenue = intermediate sales line revenue
--   3. customer lifetime sales add up to sales detail financial revenue
--   4. product lifetime revenue adds up to the same total
--   5. customer-year full-year sales add up to the same total
with checks as (
    select 'row count' as check_name,
           (select count(*) from {{ ref('mart_sales_detail') }}) as actual,
           (select count(*) from {{ ref('int_sales_lines') }})
             + (select count(*) from {{ ref('int_header_only_entries') }})
             + (select count(*) from {{ ref('int_invoices') }} where reconciliation_status = 'variance') as expected
    union all
    select 'detail revenue',
           (select sum(revenue) from {{ ref('mart_sales_detail') }}),
           (select sum(ext_price) from {{ ref('int_customer_transactions') }})
    union all
    select 'customer lifetime sales',
           (select sum(lifetime_sales) from {{ ref('mart_customers') }}),
           (select sum(revenue) from {{ ref('mart_sales_detail') }} where is_financial)
    union all
    select 'product lifetime revenue',
           (select sum(lifetime_revenue) from {{ ref('mart_products') }}),
           (select sum(revenue) from {{ ref('mart_sales_detail') }} where is_financial and row_source = 'product_line')
    union all
    select 'customer-year sales',
           (select sum(full_year_sales) from {{ ref('mart_customer_years') }}),
           (select sum(revenue) from {{ ref('mart_sales_detail') }} where is_financial)
)
select * from checks where abs(actual - expected) > 0.01
