-- One row per buy line (brand / vendor line) code: every code in the lookup plus codes that
-- appear on products but are missing from the lookup.
-- Near-duplicate codes are mapped via the buyline_map seed, but only HIGH-confidence pairs are
-- applied (decision 11). The original code is always kept.

with all_codes as (
    select buy_line, buy_line_desc, true as is_in_lookup
    from {{ ref('stg_buylines') }}

    union all

    select distinct buy_line, null, false
    from {{ ref('stg_products') }}
    where buy_line is not null
      and buy_line not in (select buy_line from {{ ref('stg_buylines') }})
)

select
    c.buy_line,
    '{{ var("company_id") }}'                           as company_id,
    coalesce(c.buy_line_desc, c.buy_line)               as buy_line_desc,   -- missing from lookup: fall back to the code
    c.is_in_lookup,
    case when m.confidence = 'high' then m.mapped_buy_line else c.buy_line end
                                                        as mapped_buy_line,
    m.confidence                                        as mapping_confidence,
    m.note                                              as mapping_note
from all_codes as c
left join {{ ref('buyline_map') }} as m
    on m.buy_line = c.buy_line
