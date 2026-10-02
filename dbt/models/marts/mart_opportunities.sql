-- Part 2: which existing customers represent the largest opportunities to recapture lost sales?
-- One row per customer who has ever purchased. Spec and reasoning: docs/OPPORTUNITY_SPEC.md.
--
-- priority_score = estimated lost gross profit x winnability x recoverability
--                = expected recoverable gross profit, ranked highest first.
-- Every comparison is like-for-like: complete years vs complete years, this year vs the same dates
-- last year, or the customer's current silence vs their own normal rhythm.
-- Thresholds and weights are dbt variables (dbt_project.yml).

with dates as (
    select
        *,
        year(as_of_date)                                    as current_year,
        strftime(as_of_date, '%b %-d')                      as as_of_label      -- e.g. "Sep 8"
    from {{ ref('int_reporting_dates') }}
),

-- The last three complete years and this year vs last year over the same dates
years as (
    select
        y.customer_id,
        max(y.full_year_gross_profit) filter (where y.sales_year = d.current_year - 3)  as gp_year_1,   -- oldest complete year
        max(y.full_year_gross_profit) filter (where y.sales_year = d.current_year - 2)  as gp_year_2,
        max(y.full_year_gross_profit) filter (where y.sales_year = d.current_year - 1)  as gp_year_3,   -- latest complete year
        max(y.same_period_gross_profit) filter (where y.sales_year = d.current_year - 1) as same_period_gp_last_year,
        max(y.same_period_gross_profit) filter (where y.sales_year = d.current_year)     as same_period_gp_this_year
    from {{ ref('mart_customer_years') }} as y
    cross join dates as d
    group by y.customer_id
),

-- Brands they stopped buying, biggest first (top 3 for the reason text)
stopped_brands as (
    select
        customer_id,
        array_to_string(list_slice(list(coalesce(brand_desc, brand) order by gp_prior_12m desc), 1, 3), ', ')
                                                            as stopped_brands,
        count(*)                                            as stopped_brand_count,
        sum(gp_prior_12m)                                   as stopped_brands_gp_prior_12m
    from {{ ref('int_customer_brand_changes') }}
    where is_stopped
    group by customer_id
),

signals as (
    select
        c.customer_id,
        c.customer_name,
        c.salesperson_name,
        c.is_house_account,
        c.home_branch_name,
        c.purchase_status,
        c.last_purchase_date,
        c.days_since_last_purchase,
        c.avg_days_between_purchases,
        c.purchase_invoice_count,
        c.gross_profit_last_12m,
        c.gross_profit_prior_12m,
        y.gp_year_1,
        y.gp_year_2,
        y.gp_year_3,
        y.same_period_gp_last_year,
        y.same_period_gp_this_year,
        b.stopped_brands,
        coalesce(b.stopped_brand_count, 0)                  as stopped_brand_count,
        coalesce(b.stopped_brands_gp_prior_12m, 0)          as stopped_brands_gp_prior_12m,
        d.current_year,
        d.as_of_date,
        d.as_of_label,

        -- A buying rhythm needs enough history to be meaningful: enough invoices, spread over more
        -- than one day (all purchases on one day gives no average gap, NULL -> false)
        coalesce(c.purchase_invoice_count >= {{ var('opp_rhythm_min_invoices') }}
                 and c.avg_days_between_purchases > 0, false)
                                                            as has_rhythm,
        c.days_since_last_purchase / nullif(c.avg_days_between_purchases, 0)
                                                            as gap_ratio,

        -- Signal 1: long-term decline = complete-year gross profit fell two years running
        coalesce(y.gp_year_2 < y.gp_year_1 and y.gp_year_3 < y.gp_year_2, false)
                                                            as is_long_term_decline,
        -- Signal 2: behind this year = same-period gross profit well below last year's same period,
        -- by a meaningful amount (a $187 baseline going to $0 is not a signal)
        coalesce(y.same_period_gp_last_year > 0
                 and y.same_period_gp_this_year <= (1 - {{ var('opp_behind_pct') }}) * y.same_period_gp_last_year
                 and y.same_period_gp_last_year - y.same_period_gp_this_year >= {{ var('opp_min_lost_gp') }}, false)
                                                            as is_behind_this_year
    from {{ ref('mart_customers') }} as c
    cross join dates as d
    left join years as y
        on y.customer_id = c.customer_id
    left join stopped_brands as b
        on b.customer_id = c.customer_id
    where c.purchase_status <> 'never_purchased'
),

with_quiet as (
    select
        *,
        -- Signal 3: gone quiet = silent for much longer than their own normal gap, or lapsed
        (has_rhythm and gap_ratio > {{ var('opp_quiet_gap_multiple') }})
            or purchase_status = 'lapsed'                   as is_gone_quiet
    from signals
),

estimates as (
    select
        *,
        -- Lost gross profit implied by each signal (0 when the signal did not fire)
        case when is_long_term_decline
             then greatest(gp_year_1, gp_year_2) - gp_year_3 else 0 end            as lost_gp_long_term,
        case when is_behind_this_year
             then same_period_gp_last_year - same_period_gp_this_year else 0 end   as lost_gp_this_year,
        case when is_gone_quiet
             then greatest(gross_profit_prior_12m - gross_profit_last_12m, 0) else 0 end
                                                                                   as lost_gp_gone_quiet,

        case
            when (is_behind_this_year or is_gone_quiet) and not is_long_term_decline then 'early_warning'
            when (is_behind_this_year or is_gone_quiet) and is_long_term_decline     then 'long_term_decline'
            when is_long_term_decline                                                then 'recovering'
        end                                                                        as opportunity_type,

        -- Recoverability: how recently they bought, relative to their own rhythm where they have one
        case
            when purchase_status = 'lapsed'                 then 0.5
            when has_rhythm and gap_ratio <= 2              then 1.0
            when has_rhythm and gap_ratio <= 4              then 0.8
            when has_rhythm                                 then 0.5
            when days_since_last_purchase <= 90             then 1.0
            when days_since_last_purchase <= 365            then 0.8
            else 0.5
        end                                                                        as recoverability_factor
    from with_quiet
),

scored as (
    select
        *,
        -- The signals often describe the same drop, so take the largest estimate, not the sum
        greatest(lost_gp_long_term, lost_gp_this_year, lost_gp_gone_quiet)        as est_lost_gross_profit,
        case opportunity_type
            when 'early_warning'     then {{ var('opp_weight_early_warning') }}
            when 'long_term_decline' then {{ var('opp_weight_long_term_decline') }}
            when 'recovering'        then {{ var('opp_weight_recovering') }}
            else 0
        end                                                                        as winnability_weight
    from estimates
),

flagged as (
    select
        *,
        est_lost_gross_profit * winnability_weight * recoverability_factor          as priority_score,
        opportunity_type is not null
            and est_lost_gross_profit >= {{ var('opp_min_lost_gp') }}               as is_flagged
    from scored
)

select
    customer_id,
    '{{ var("company_id") }}'                                                       as company_id,
    customer_name,
    case when salesperson_name is null or is_house_account then 'Unassigned'
         else salesperson_name end                                                  as salesperson,
    home_branch_name,

    is_flagged,
    case when is_flagged
         then rank() over (partition by is_flagged order by priority_score desc) end as opportunity_rank,
    opportunity_type,
    round(priority_score, 2)                                                        as priority_score,
    round(est_lost_gross_profit, 2)                                                 as est_lost_gross_profit,
    winnability_weight,
    recoverability_factor,

    -- Plain-English reason, built from whichever signals fired
    concat_ws('; ',
        case when is_long_term_decline then
            format('Gross profit down two years running ({} in {} to {} in {})',
                   {{ fmt_money('greatest(gp_year_1, gp_year_2)') }},
                   case when gp_year_1 >= gp_year_2 then current_year - 3 else current_year - 2 end,
                   {{ fmt_money('gp_year_3') }}, current_year - 1) end,
        case when is_behind_this_year then
            format('{} so far is {}% behind last year through {} ({} vs {} gross profit)',
                   current_year,
                   round(100 * (1 - same_period_gp_this_year / same_period_gp_last_year))::int,
                   as_of_label,
                   {{ fmt_money('same_period_gp_this_year') }}, {{ fmt_money('same_period_gp_last_year') }}) end,
        case when purchase_status = 'lapsed' then
            format('No purchase in over 12 months (last on {})', strftime(last_purchase_date, '%Y-%m-%d'))
             when is_gone_quiet then
            format('No purchase for {} days; normally buys every {} days',
                   days_since_last_purchase, round(avg_days_between_purchases)::int) end,
        case when stopped_brand_count > 0 then
            format('Stopped buying {}', stopped_brands) end
    )                                                                               as reason,

    -- Signals and the numbers behind them
    is_long_term_decline,
    is_behind_this_year,
    is_gone_quiet,
    gp_year_1                                                                       as gp_oldest_complete_year,
    gp_year_2                                                                       as gp_middle_complete_year,
    gp_year_3                                                                       as gp_latest_complete_year,
    same_period_gp_last_year,
    same_period_gp_this_year,
    gross_profit_prior_12m,
    gross_profit_last_12m,
    last_purchase_date,
    days_since_last_purchase,
    avg_days_between_purchases,
    round(gap_ratio, 2)                                                             as gap_ratio,
    lost_gp_long_term,
    lost_gp_this_year,
    lost_gp_gone_quiet,
    stopped_brands,
    stopped_brand_count,
    stopped_brands_gp_prior_12m,
    purchase_status,
    as_of_date
from flagged
