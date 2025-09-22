-- Example model to validate dbt <-> Trino connectivity
select
  current_timestamp as run_at,
  '{{ target.name }}' as target_name,
  count(*) as table_count
from information_schema.tables
