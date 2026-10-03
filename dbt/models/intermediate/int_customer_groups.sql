-- Every customer account mapped to the customer it belongs to. ADH confirmed that related bill-to
-- accounts (tax / non-tax, install / service, duplicates) are one customer. The pairs are a
-- reviewable seed (customer_groups) built from matching names and the customer master's own links;
-- accounts not in the seed are their own customer.

select
    c.customer_id                                               as account_id,
    c.company_id,
    coalesce(g.group_customer_id, c.customer_id)                as customer_id,
    g.reason                                                    as grouping_reason
from {{ ref('stg_customers') }} as c
left join {{ ref('customer_groups') }} as g
    on g.customer_id = c.customer_id
