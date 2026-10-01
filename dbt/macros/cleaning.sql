-- Small helpers used by every staging model, so cleanup rules live in one place.

-- Trim text and turn blank strings into NULL.
-- Also repairs the few garbled characters found in this extract:
--   * text the ERP double-encoded (UTF-8 saved as latin-1): ’ á è
--   * non-breaking spaces and stray null bytes
{% macro clean_text(column) -%}
    nullif(trim(
        replace(replace(replace(replace(replace(replace({{ column }},
            chr(226) || chr(128) || chr(153), ''''),   -- ’ (curly apostrophe) -> '
            chr(195) || chr(161), 'á'),
            chr(195) || chr(168), 'è'),
            chr(194) || chr(160), ' '),                -- double-encoded non-breaking space
            chr(160), ' '),                            -- non-breaking space
            chr(0), '')
    ), '')
{%- endmacro %}

-- Source dates are MM/DD/YYYY text. strptime fails loudly on a bad value (we want that).
{% macro to_date(column) -%}
    cast(strptime(nullif(trim({{ column }}), ''), '%m/%d/%Y') as date)
{%- endmacro %}

-- Money and other amounts. 4 decimals covers every source (inventory costs have 3).
{% macro to_amount(column) -%}
    cast({{ column }} as decimal(18, 4))
{%- endmacro %}
