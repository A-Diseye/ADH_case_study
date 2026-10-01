-- Product type: EQ equipment, PA parts, IS installation supply, OT other.
select
    {{ clean_text('GL_Type') }}                     as gl_type,
    '{{ var("company_id") }}'                       as company_id,
    {{ clean_text('GLType_Description') }}          as gl_type_desc
from {{ source('raw', 'gltypes') }}
