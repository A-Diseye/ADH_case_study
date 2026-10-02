# Part 2: Opportunity model spec

**The sales team's question:** *Which existing customers appear to represent the largest opportunities for us to recapture lost sales?*

**Opportunity** = estimated gross profit a customer used to give us and no longer does. Because the question is about what we can **recapture**, the score is **expected recoverable gross profit**: lost gross profit weighted by how winnable the customer is, so easier saves rank above harder win-backs.

Built as one dbt model, `mart_opportunities` (one row per customer who has ever purchased), on top of the marts. The app reads it directly. Thresholds are dbt variables so they can be changed in one place.

## 1. Signals (all like-for-like; a partial year is never compared with a full one)

| Signal | Rule (draft threshold) | Estimated lost gross profit | Source |
|---|---|---|---|
| **Declining** | Full-year GP fell two years running (2023 > 2024 > 2025), **or** a sharp drop: 2025 at least **25%** (and $1K) below **both** 2023 and 2024 | Two years running: best of 2023/2024 minus 2025. Sharp drop: the **lower** of 2023/2024 minus 2025 | `mart_customer_years.full_year_*` |
| **Behind this year** | 2026 GP from Jan 1 to the as-of day is at least **10%** below the same period of 2025 | 2025 same-period GP minus 2026 same-period GP | `mart_customer_years.same_period_*` |
| **Gone quiet** | No purchase for more than **4x** their normal gap between purchases (customers with 5+ purchase invoices), or no purchase at all in the last 12 months | Prior-12-month GP minus last-12-month GP | `mart_customers` |
| **Mostly stopped buying a brand** | A brand worth at least **$1K** GP to them in the prior 12 months, down **80%** or more in the last 12 (not "went to zero": A & L's top brand went from $74.7K to $562, and a zero-only rule hid it) | (used for the reason and Part 4, not added to the estimate) | `int_customer_brand_changes` |

**Estimated lost GP = the largest of the three signal estimates**, not the sum, because the signals often describe the same drop.

### Why "gone quiet" works this way

- **Each customer is judged against their own rhythm.** The normal gap is their average days between purchases (`avg_days_between_purchases`). 45 days without an order is alarming for a weekly buyer but normal for one who orders every two months; a single fixed cut-off (e.g. 30 days) would flag the second and react too slowly to the first.
- **5+ purchase invoices required:** an average needs enough history to describe a real pattern; two purchases give one gap, which is not a rhythm.
- **Lapsed customers (no purchase in 12 months) are always included**, which catches customers with too little history for a rhythm.
- **Why 4x, not 3x (measured):** across ~58,000 completed gaps (the customer did come back), a gap over 2x their average happens 11.0% of the time, over 3x 3.8%, over 4x 1.8%, over 5x 1.0%. With ~580 customers who have 5+ invoices, chance alone would put ~10 over 4x at any moment, and 96 are; between 3x and 4x chance would put ~12, and 20 are, so more than half of the extra customers a 3x rule adds could be a normal quiet patch. 4x keeps the list mostly real; customers who are truly slipping usually also show up as "behind this year", so the slightly later warning costs little. 5x would be needlessly slow.

### Why "declining" has two triggers

- **Sharp drop (added after review):** two-years-running missed customers who were steady and then collapsed in one year, e.g. A & L of NC ($495K, $510K, then $58K), the largest real loss in the data, which had been ranked as a $47K early warning. Requiring the drop against **both** earlier years, and measuring the loss from the **lower** of them, means a one-off spike year (a big project) can never create or inflate it: Columbus County ($16K, $150K, $28K) is correctly not flagged. 14 customers meet it, 10 of them newly flagged.

- One down year can be a slow season, a lost job or timing; two consecutive declines show a trend.
- **Customers who dropped to $0 and stayed there are deliberately excluded** (e.g. $46K in 2023, nothing since). The question is about *existing* customers; 6 customers ($106K of 2023 gross profit) fit this pattern, and most last bought in 2023, so they are former customers rather than recapture opportunities. Changing the rule to "fell, then stayed down" (`2025 <= 2024`) would include them if needed.
- Customers with only one or two years of history can never trigger this signal (missing years count as $0, so there is no two-year fall); they can still be flagged by the other two signals.
- With three complete years (2023, 2024, 2025) there are only two year-over-year steps, so two years running is also the most the data allows. As more complete years arrive, the rule can stay at "two consecutive declines" on the latest years.

### Why "behind this year" uses 10%

- **Being proactive:** reaching out when a customer starts to fall behind beats waiting until they are far behind.
- **Measured: early drops predict full-year drops.** In past years (2024 vs 2023, 2025 vs 2024, customers with $2K+ same-period GP), customers down 10-15% by Sep 8 ended the full year down 83% of the time (67% down 10%+); down 20-40% ended down 85%; up or flat by Sep 8 ended down only 6%. Customers rarely catch up in Q4. (Some groups are small, e.g. 12 cases at 10-15%, so this supports the choice rather than proving an exact number.)
- **Low cost:** 10% instead of 20% adds 11 customers (132 to 143) and ~$43K estimated lost GP. Because the list is ranked by score, milder cases sit lower and never push the big losses down.
- **Why not lower:** customers down 0-10% usually ended only slightly down (45% ended down 10%+), which is closer to normal variation; the $1K minimum filters most of them anyway.

## 2. Winnability (the scenarios)

| Scenario (`opportunity_type`) | Weight | Why |
|---|---|---|
| Steady or growing before, **now** behind or quiet (`early_warning`) | **1.0** | Easiest to win back: the relationship is warm and the cause is recent and often fixable (service, price, a competitor's rep). The drop is real: in past years 83-85% of customers 10-40% behind by Sep 8 ended the year down |
| Declining **and** still behind or quiet, **or lapsed** (no purchase in 12 months) (`declining`) | **0.7** | The loss is certain, but they have likely moved business elsewhere already, so harder to recapture |
| Declining, but on track this year (`recovering`) | **0.4** | Already stabilising on their own; least urgent |
| Lapsed **and** under $1K in both recent complete years (`former_customer`) | not flagged | Not an *existing* customer (e.g. EMI Service: $204K in 2023, one $427 order in 2024, nothing since). Labelled so a separate reactivation list is one filter away, but never ranked |
| None of the above | not flagged | |

Common sales practice: saving a customer who is starting to drift is cheaper and succeeds more often than winning back one who has mostly left. A large long-term decliner can still rank high; it just needs more lost profit to outrank an easier save. `opportunity_type` lets reps filter to "save" or "win-back" calls. There is no outreach-outcome data (contact or win/loss history) to measure winnability directly, so these weights are a judgement.

## 3. Recoverability (how recently they bought, relative to their own rhythm)

| Days since last purchase / their normal gap | Factor | Why |
|---|---|---|
| Up to 2x | 1.0 | Within their normal rhythm: the relationship is live |
| 2x to 4x | 0.8 | Later than usual |
| Over 4x, or lapsed (no purchase in 12 months) | 0.5 | Harder to win back |
| Fewer than 5 purchase invoices (no reliable rhythm) | fixed days: up to 90 = 1.0, 91-365 = 0.8, over 365 = 0.5 | |

Relative to their rhythm so an infrequent buyer (e.g. every 100 days) is not marked down for a gap that is normal for them. Uses the same 2x / 4x cut-offs as "gone quiet".

## 4. Score and output

- **Priority score = estimated lost GP x winnability x recoverability** (expected recoverable gross profit), ranked highest first.
- **Flagged** when estimated lost GP is at least **$1,000** (removes small-customer noise; 626 customers made under $1K GP in 2025).
- Each row has: customer, salesperson (or "unassigned"), home branch, `opportunity_type`, the signals that fired, the key numbers behind them, estimated lost GP, score, rank, and a **plain-English reason**, e.g.
  *"Gross profit down 3 years running ($72K in 2023 to $41K in 2025); 2026 so far is 35% behind the same period last year. Mostly stopped buying HEIL and SUPCO."*
- A supporting model, `int_customer_brand_changes` (customer x brand, prior vs last 12 months), feeds the "mostly stopped buying" list and is reused by the Part 4 call sheet.

**Result on current data:** 202 customers flagged, about $3.03M estimated lost gross profit, $1.88M expected recoverable (121 early warning, 47 declining, 34 recovering); 201 former customers labelled, not flagged. #1 is A & L of NC ($438K lost). "Behind this year" also requires a shortfall of at least $1K, so a tiny baseline (e.g. $187 to $0) does not fire it.

## 5. Depends on pending ADH answers (defaults used until answered)

| Question | Effect if the default changes |
|---|---|
| Ext_Cost vs COGS | Gross profit column changes everywhere (one place: intermediate) |
| Rebates | Net `adjustment_amount` rebates into lost GP |
| Related bill-to accounts | Group related accounts before scoring (a small mapping seed) |
| Account ownership | Fills in salesperson for unassigned customers; does not change scores |

Salesperson is shown, not scored, so the ownership answer cannot move a customer up or down the list.

## 6. Weaknesses to state

- Seasonality is handled by like-for-like periods only; a per-customer seasonal projection is a next step.
- A drop may mean fewer projects, not a lost customer; we have no quote, pipeline or competitor data.
- One large past project can look like a decline afterwards (the multi-year view reduces but does not remove this).
- Thresholds (10%, 4x, $1K) and weights (1.0 / 0.7 / 0.4 and 1.0 / 0.8 / 0.5) are judgement calls, chosen from the data profile and easy to change.
