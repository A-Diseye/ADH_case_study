-- The reporting windows, defined once. "Recent" periods roll back from the latest ship date in
-- the data, never from today's date or a hardcoded date, so they stay correct when new data loads.
-- Windows are inclusive of the end date: last 12 months = (as_of - 12 months, as_of].

with latest as (
    select max(ship_date) as as_of_date
    from {{ ref('int_sales_lines') }}
)

select
    as_of_date,
    cast(as_of_date - interval 12 month as date)    as last_12m_start,      -- exclusive
    cast(as_of_date - interval 24 month as date)    as prior_12m_start      -- exclusive
from latest
