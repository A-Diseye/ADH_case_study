"""
ADH win-back opportunities: a simple app for salespeople (Part 3).

Reads the dbt marts in data/adh.duckdb (build them first: cd dbt && dbt build).
Run:  streamlit run app/app.py
"""

from pathlib import Path

import duckdb
import pandas as pd
import streamlit as st

DB_PATH = Path(__file__).resolve().parents[1] / "data" / "adh.duckdb"

st.set_page_config(page_title="ADH Win-back Opportunities", layout="wide")


@st.cache_data
def query(sql: str, params: tuple = ()) -> pd.DataFrame:
    """Run a query on a short-lived read-only connection, so the app never blocks dbt from writing."""
    with duckdb.connect(str(DB_PATH), read_only=True) as con:
        return con.execute(sql, list(params)).df()



# ---------------------------------------------------------------- data
opps = query("""
    select opportunity_rank, customer_id, customer_name, salesperson, home_branch_name,
           opportunity_type, priority_score, est_lost_gross_profit, reason,
           last_purchase_date, days_since_last_purchase, as_of_date
    from marts.mart_opportunities
    where is_flagged
    order by opportunity_rank
""")
as_of = pd.to_datetime(opps["as_of_date"].iloc[0]).date()

# Show opportunity types in plain English rather than the model's codes
TYPE_LABELS = {"early_warning": "Early warning", "declining": "Declining", "recovering": "Recovering"}
opps["opportunity_type"] = opps["opportunity_type"].map(TYPE_LABELS)

# ---------------------------------------------------------------- sidebar filters
st.sidebar.header("Filters")
reps = st.sidebar.multiselect("Salesperson", sorted(opps["salesperson"].unique()))
branches = st.sidebar.multiselect("Home branch", sorted(opps["home_branch_name"].dropna().unique()))
types = st.sidebar.multiselect(
    "Opportunity type", list(TYPE_LABELS.values()),
    help="Early warning: steady before, slipping now (easiest to save). "
         "Declining: down two years running, a sharp drop, or no purchase in 12 months. "
         "Recovering: declined before, on track this year.",
)
min_score = st.sidebar.number_input("Minimum recoverable gross profit ($)", min_value=0, value=0, step=1000)

view = opps
if reps:
    view = view[view["salesperson"].isin(reps)]
if branches:
    view = view[view["home_branch_name"].isin(branches)]
if types:
    view = view[view["opportunity_type"].isin(types)]
view = view[view["priority_score"] >= min_score]

# ---------------------------------------------------------------- header
st.title("Win-back opportunities")
st.caption(
    f"Existing customers ranked by the gross profit we could realistically recapture. "
    f"Data through {as_of:%b %d, %Y}."
)
with st.expander("How the ranking works"):
    st.markdown(
        """
**Recoverable gross profit = estimated lost gross profit x winnability x recoverability.**
Customers are ranked by it, so the top of the list is the profit we are most likely to win back.

**Estimated lost gross profit** comes from whichever of these signals shows the biggest drop
(every comparison is like-for-like, so seasonality does not create false drops):
- **Declining:** gross profit fell two complete years running, or dropped sharply (25%+ below both earlier years).
- **Behind this year:** this year so far is 10%+ below the same dates last year.
- **Gone quiet:** no purchase for 4x longer than this customer's normal gap between orders, or none in 12 months.

**Winnability** by type: **early warning** (steady before, slipping now: easiest to save) counts 100%;
**declining** (or no purchase in 12 months) 70%; **recovering** (declined, but on track this year) 40%.

**Recoverability:** still buying within their normal rhythm counts 100%; later than usual 80%; long silent 50%.

Only customers with at least \\$1,000 of estimated lost gross profit are listed. Customers gone for over a year
with almost nothing since are treated as former customers and left off.
"""
    )

c1, c2, c3 = st.columns(3)
c1.metric("Customers to call", f"{len(view):,}")
c2.metric("Estimated lost gross profit", f"${view['est_lost_gross_profit'].sum():,.0f}")
c3.metric("Expected recoverable", f"${view['priority_score'].sum():,.0f}")

# ---------------------------------------------------------------- ranked list
st.subheader("Ranked list")
st.dataframe(
    view[["opportunity_rank", "customer_name", "salesperson", "home_branch_name", "opportunity_type",
          "priority_score", "est_lost_gross_profit", "reason"]],
    hide_index=True,
    width="stretch",
    column_config={
        "opportunity_rank": st.column_config.NumberColumn("Rank"),
        "customer_name": "Customer",
        "salesperson": "Salesperson",
        "home_branch_name": "Branch",
        "opportunity_type": "Type",
        "priority_score": st.column_config.NumberColumn("Recoverable GP", format="dollar"),
        "est_lost_gross_profit": st.column_config.NumberColumn("Lost GP", format="dollar"),
        "reason": st.column_config.TextColumn("Why flagged", width="large"),
    },
)
st.download_button(
    "Download this list (CSV)",
    view.drop(columns=["as_of_date"]).to_csv(index=False),
    file_name="win_back_opportunities.csv",
    mime="text/csv",
)

# ---------------------------------------------------------------- customer drill-down
st.divider()
st.subheader("Customer detail")
if view.empty:
    st.info("No customers match these filters.")
    st.stop()

labels = {f"#{r.opportunity_rank}  {r.customer_name}": r.customer_id for r in view.itertuples()}
customer_id = labels[st.selectbox("Choose a customer", list(labels))]
cust = query("select * from marts.mart_opportunities where customer_id = ?", (customer_id,)).iloc[0]

contact = query("""
    select city, state, phone, email from marts.mart_customers where customer_id = ?
""", (customer_id,)).iloc[0]
details = [f"**Salesperson:** {cust['salesperson']}", f"**Branch:** {cust['home_branch_name'] or 'n/a'}"]
details.append(f"**Location:** {', '.join(x for x in [contact['city'], contact['state']] if x) or 'n/a'}")
details.append(f"**Phone:** {contact['phone'] or 'n/a'}")
details.append(f"**Email:** {contact['email'] or 'n/a'}")
st.markdown(f"### {cust['customer_name']}")
st.markdown("  |  ".join(details))
# Escape $ so markdown does not render the text between two dollar amounts as a maths formula
st.markdown(f"**Why flagged:** {cust['reason'].replace('$', chr(92) + '$')}")
k1, k2, k3, k4 = st.columns(4)
k1.metric("Last purchase", f"{pd.to_datetime(cust['last_purchase_date']):%b %d, %Y}")
k1.caption(f"{cust['days_since_last_purchase']:.0f} days before the latest data")
k2.metric("Normally buys every", "n/a" if pd.isna(cust["avg_days_between_purchases"])
          else f"{cust['avg_days_between_purchases']:.0f} days")
k3.metric("GP last 12 months", f"${cust['gross_profit_last_12m']:,.0f}",
          f"{cust['gross_profit_last_12m'] - cust['gross_profit_prior_12m']:+,.0f} vs prior 12")
k4.metric(f"GP Jan 1 - {as_of:%b %d}, this year", f"${cust['same_period_gp_this_year']:,.0f}",
          f"{cust['same_period_gp_this_year'] - cust['same_period_gp_last_year']:+,.0f} vs last year")

left, right = st.columns(2)
with left:
    st.markdown("**Gross profit by month**")
    monthly = query("""
        select date_trunc('month', ship_date) as month, sum(gross_profit) as gross_profit
        from marts.mart_sales_detail
        where bill_to_customer_id = ? and is_financial and row_source = 'product_line'
        group by 1 order by 1
    """, (customer_id,))
    st.bar_chart(monthly, x="month", y="gross_profit", height=260)
    if as_of != (pd.Timestamp(as_of) + pd.offsets.MonthEnd(0)).date():
        st.caption(f"The last bar ({as_of:%B %Y}) is a partial month: data ends on {as_of:%b %d}, "
                   f"so it is not a real drop.")

    st.markdown("**By year** (same period = Jan 1 to the latest data date, every year)")
    years = query("""
        select sales_year as year, full_year_gross_profit, same_period_gross_profit,
               case when is_partial_year then '✓' else '' end as partial_year   -- text, not a checkbox
        from marts.mart_customer_years where customer_id = ? order by sales_year
    """, (customer_id,))
    st.dataframe(years, hide_index=True, width="stretch", column_config={
        "year": st.column_config.NumberColumn("Year", format="%d"),
        "full_year_gross_profit": st.column_config.NumberColumn("Full-year GP", format="dollar"),
        "same_period_gross_profit": st.column_config.NumberColumn("Same-period GP", format="dollar"),
        "partial_year": "Partial year",
    })

with right:
    st.markdown("**Brands: last 12 months vs the 12 before** (biggest drops first)")
    # Same model (and the same windows and 80% rule) that writes "Mostly stopped buying" in the reason
    brands = query("""
        select coalesce(brand_desc, brand) as brand,
               coalesce(gp_prior_12m, 0) as gp_prior_12m,
               coalesce(gp_last_12m, 0) as gp_last_12m,
               case when is_mostly_stopped then '✓' else '' end as mostly_stopped
        from intermediate.int_customer_brand_changes
        where customer_id = ?
        order by coalesce(gp_last_12m, 0) - coalesce(gp_prior_12m, 0)
        limit 15
    """, (customer_id,))
    st.dataframe(brands, hide_index=True, width="stretch", column_config={
        "brand": "Brand", "gp_prior_12m": st.column_config.NumberColumn("GP prior 12m", format="dollar"),
        "gp_last_12m": st.column_config.NumberColumn("GP last 12m", format="dollar"),
        "mostly_stopped": "Mostly stopped",
    })

    st.markdown("**Recent invoices**")
    invoices = query("""
        select ship_date, invoice_no, ship_branch_name as branch, count(*) as lines,
               sum(revenue) as sales, sum(gross_profit) as gross_profit
        from marts.mart_sales_detail
        where bill_to_customer_id = ? and is_financial and row_source = 'product_line'
        group by all order by ship_date desc limit 15
    """, (customer_id,))
    st.dataframe(invoices, hide_index=True, width="stretch", column_config={
        "ship_date": st.column_config.DateColumn("Date"), "invoice_no": "Invoice", "branch": "Branch",
        "lines": "Lines", "sales": st.column_config.NumberColumn("Sales", format="dollar"), "gross_profit": st.column_config.NumberColumn("Gross profit", format="dollar"),
    })

# ---------------------------------------------------------------- reference
with st.expander("Product type reference (what each product type includes)"):
    st.dataframe(query("""
        with by_brand as (
            select product_type, product_type_desc, coalesce(brand_desc, brand) as brand,
                   sum(revenue_last_12m) as revenue
            from marts.mart_products
            where not is_non_product and product_type is not null
            group by all
        )
        select product_type as code, product_type_desc as product_type,
               count(*) filter (where revenue > 0) as brands_sold_last_12m,
               sum(revenue) as revenue_last_12m,
               array_to_string(list_slice(list(brand order by revenue desc), 1, 5), ', ') as top_brands
        from by_brand group by all order by revenue_last_12m desc
    """), hide_index=True, width="stretch", column_config={
        "revenue_last_12m": st.column_config.NumberColumn("Revenue last 12m", format="dollar"),
    })
    st.caption("The source has no finer category data (commodity codes are nearly empty), "
               "so the hierarchy is product type, then brand, then sell group.")
