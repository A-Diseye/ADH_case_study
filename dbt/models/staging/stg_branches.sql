select
    {{ clean_text('Branch') }}                      as branch_id,
    '{{ var("company_id") }}'                       as company_id,
    {{ clean_text('Short_Desc') }}                  as branch_short_name,
    {{ clean_text('Branch_Description') }}          as branch_name
from {{ source('raw', 'branches') }}
