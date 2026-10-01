-- Buy line = brand / vendor product line. Near-duplicate codes are handled in intermediate.
select
    {{ clean_text('Buy_Line') }}                    as buy_line,
    '{{ var("company_id") }}'                       as company_id,
    {{ clean_text('BLine_Description') }}           as buy_line_desc
from {{ source('raw', 'buylines') }}
