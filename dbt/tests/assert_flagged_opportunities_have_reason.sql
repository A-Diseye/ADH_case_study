-- Every flagged opportunity must have a rank and a reason a salesperson can read.
select customer_id
from {{ ref('mart_opportunities') }}
where is_flagged and (opportunity_rank is null or reason is null or reason = '')
