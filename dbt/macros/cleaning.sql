-- Small helpers used by every staging model, so cleanup rules live in one place.

-- Trim text and turn blank strings into NULL, after repairing the few garbled
-- characters found in this extract. Each fix is one (bad, good, what it is) entry below;
-- they are applied in order. Bad and good are SQL expressions: the bad values use chr()
-- because they are invisible or garbled characters that can't be typed reliably.
{% macro clean_text(column) -%}
    {%- set fixes = [
        ("chr(226) || chr(128) || chr(153)", "''''", "curly apostrophe, double-encoded by the ERP -> plain apostrophe"),
        ("chr(195) || chr(161)",             "'á'",  "á, double-encoded"),
        ("chr(195) || chr(168)",             "'è'",  "è, double-encoded"),
        ("chr(194) || chr(160)",             "' '",  "non-breaking space, double-encoded -> space"),
        ("chr(160)",                         "' '",  "non-breaking space -> space"),
        ("chr(0)",                           "''",   "stray null byte -> removed"),
    ] -%}

    {#- Wrap the column in one replace() per fix: replace(replace(column, bad1, good1), bad2, good2) ... -#}
    {%- set ns = namespace(sql=column) -%}
    {%- for bad, good, _description in fixes -%}
        {%- set ns.sql = "replace(" ~ ns.sql ~ ", " ~ bad ~ ", " ~ good ~ ")" -%}
    {%- endfor -%}

    nullif(trim({{ ns.sql }}), '')
{%- endmacro %}

-- Source dates are MM/DD/YYYY text. strptime fails loudly on a bad value (we want that).
{% macro to_date(column) -%}
    cast(strptime(nullif(trim({{ column }}), ''), '%m/%d/%Y') as date)
{%- endmacro %}

-- Money and other amounts. 4 decimals covers every source (inventory costs have 3).
{% macro to_amount(column) -%}
    cast({{ column }} as decimal(18, 4))
{%- endmacro %}

-- Whole dollars with thousands separators for reason text: 1234.5 -> $1,235, -250 -> -$250
{% macro fmt_money(column) -%}
    case when {{ column }} < 0 then '-$' else '$' end || format('{:,}', abs(round({{ column }}))::bigint)
{%- endmacro %}
