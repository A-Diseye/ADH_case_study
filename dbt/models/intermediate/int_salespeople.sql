-- One row per salesperson ID, mapped to a person.
--   * person_id: one person can have several IDs (e.g. COLES / COLESPU for Cole Sutton). IDs whose
--     names match (ignoring case) are grouped, and the most-used ID represents the person.
--   * is_system_account: house / web / admin IDs that are not a real salesperson (seed list).
--   * IDs used in sales or the customer master but missing from the lookup (JAMESD) are included
--     with no name, so joins never drop rows.

with id_usage as (
    select salesperson_id, count(*) as uses
    from (
        select outside_salesperson_id as salesperson_id from {{ ref('stg_sales') }}
        union all
        select inside_salesperson_id from {{ ref('stg_sales') }}
        union all
        select salesperson_id from {{ ref('stg_customers') }}
    )
    where salesperson_id is not null
    group by salesperson_id
),

all_ids as (
    select salesperson_id, salesperson_name, true as is_in_lookup
    from {{ ref('stg_salespeople') }}

    union all

    select salesperson_id, null, false
    from id_usage
    where salesperson_id not in (select salesperson_id from {{ ref('stg_salespeople') }})
),

with_person as (
    select
        a.*,
        coalesce(u.uses, 0)                                     as uses,
        -- Same name (ignoring case) = same person. IDs with no name stand alone.
        coalesce(upper(a.salesperson_name), a.salesperson_id)   as person_key
    from all_ids as a
    left join id_usage as u
        on u.salesperson_id = a.salesperson_id
)

select
    salesperson_id,
    '{{ var("company_id") }}'                                   as company_id,
    salesperson_name,
    first(salesperson_id) over (
        partition by person_key order by uses desc, salesperson_id
    )                                                           as person_id,
    first(salesperson_name) over (
        partition by person_key order by uses desc, salesperson_id
    )                                                           as person_name,
    salesperson_id in (select salesperson_id from {{ ref('salesperson_system_accounts') }})
                                                                as is_system_account,
    is_in_lookup,
    uses                                                        as usage_count
from with_person
