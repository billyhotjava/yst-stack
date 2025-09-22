#!/usr/bin/env bash
set -euo pipefail

sql_escape_literal() {
  local value="${1-}"
  local squote="'"
  local doubled="''"
  value=${value//${squote}/${doubled}}
  printf '%s' "${value}"
}

ensure_pg_role_and_db() {
  local role="${1:-}"
  local password="${2:-}"
  local database="${3:-}"

  if [[ -z "${role}" || -z "${password}" || -z "${database}" ]]; then
    echo "[yts-pg] Missing variables for role/database initialization, skip." >&2
    return 0
  fi

  local role_literal
  local role_pwd_literal
  local db_literal
  role_literal="$(sql_escape_literal "${role}")"
  role_pwd_literal="$(sql_escape_literal "${password}")"
  db_literal="$(sql_escape_literal "${database}")"

  "${psql[@]}" <<SQL
DO \$do$
DECLARE
  role_name text := '${role_literal}';
  role_pwd text := '${role_pwd_literal}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', role_name, role_pwd);
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', role_name, role_pwd);
  END IF;
END
\$do$;

SQL

  "${psql[@]}" <<SQL
SELECT format(
  'CREATE DATABASE %s OWNER %s',
  quote_ident('${db_literal}'),
  quote_ident('${role_literal}')
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = '${db_literal}'
)
\gexec

SELECT format(
  'ALTER DATABASE %s OWNER TO %s',
  quote_ident('${db_literal}'),
  quote_ident('${role_literal}')
)
\gexec
SQL
}

ensure_pg_roles() {
  ensure_pg_role_and_db "${PG_USER_KEYCLOAK-}" "${PG_PWD_KEYCLOAK-}" "${PG_DB_KEYCLOAK-}"
  ensure_pg_role_and_db "${PG_USER_AIRBYTE-}" "${PG_PWD_AIRBYTE-}" "${PG_DB_AIRBYTE-}"
  ensure_pg_role_and_db "${PG_USER_AIRBYTE_JOBS-}" "${PG_PWD_AIRBYTE_JOBS-}" "${PG_DB_AIRBYTE_JOBS-}"
  ensure_pg_role_and_db "${PG_USER_OM-}" "${PG_PWD_OM-}" "${PG_DB_OM-}"
  ensure_pg_role_and_db "${PG_USER_TEMPORAL-}" "${PG_PWD_TEMPORAL-}" "${PG_DB_TEMPORAL-}"
  ensure_pg_role_and_db "${PG_USER_TEMPORAL-}" "${PG_PWD_TEMPORAL-}" "${PG_DB_TEMPORAL_VISIBILITY-}"
  ensure_pg_role_and_db "${PG_USER_RANGER-}" "${PG_PWD_RANGER-}" "${PG_DB_RANGER-}"
  ensure_pg_role_and_db "${PG_USER_RANGER_AUDIT-}" "${PG_PWD_RANGER_AUDIT-}" "${PG_DB_RANGER_AUDIT-}"
}
