-- One row per salesperson ID. One person can have several IDs; mapping happens in intermediate.
select
    {{ clean_text('Salespsn') }}                    as salesperson_id,
    '{{ var("company_id") }}'                       as company_id,
    {{ clean_text('Salesperson_Name') }}            as salesperson_name
from {{ source('raw', 'salespeople') }}
