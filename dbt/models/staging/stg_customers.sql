-- One row per customer account (the master is keyed by ship-to account).
-- Rolling accounts up to their bill-to customer happens in intermediate.

select
    {{ clean_text('ST_Cus_ID') }}                   as customer_id,
    '{{ var("company_id") }}'                       as company_id,
    {{ clean_text('BT_Cus_ID') }}                   as bill_to_customer_id,

    {{ clean_text('Customer_Name') }}               as customer_name,
    {{ clean_text('Address1') }}                    as address_1,
    {{ clean_text('Address2') }}                    as address_2,
    {{ clean_text('City') }}                        as city,
    {{ clean_text('ST') }}                          as state,
    {{ clean_text('Zip') }}                         as zip,
    {{ clean_text('Phone') }}                       as phone,
    {{ clean_text('Fax') }}                         as fax,
    {{ clean_text('Email') }}                       as email,

    {{ clean_text('Salespsn') }}                    as salesperson_id,
    {{ clean_text('In_Slsp') }}                     as inside_salesperson_id,
    {{ clean_text('HmBr') }}                        as home_branch_id,
    {{ clean_text('Cust_Type') }}                   as customer_type,
    {{ clean_text('Class') }}                       as customer_class,
    {{ clean_text('Terms_Code') }}                  as terms_code,

    -- Inactive is 1 (727), 0 (275) or blank (3,168). Blank is treated as active.
    coalesce(Inactive = '1', false)                 as is_inactive,

    {{ to_date('Last_Pay_Date') }}                  as last_payment_date,
    {{ to_amount('Last_Pay_Amt') }}                 as last_payment_amount,
    {{ to_amount('Credit_Limit') }}                 as credit_limit,
    {{ to_amount('Limit_Used') }}                   as credit_used,
    cast(Average_Debtor_Days as integer)            as avg_debtor_days,

    _source_file,
    cast(_source_line as integer)                   as _source_line,
    _loaded_at
from {{ source('raw', 'customers') }}
