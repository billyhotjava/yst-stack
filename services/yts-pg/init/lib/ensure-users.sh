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

DO \$do$
DECLARE
  role_name text := '${role_literal}';
  db_name text := '${db_literal}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = db_name) THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', db_name, role_name);
  ELSE
    EXECUTE format('ALTER DATABASE %I OWNER TO %I', db_name, role_name);
  END IF;
END
\$do$;
SQL
}

ensure_pg_roles() {
  ensure_pg_role_and_db "${PG_USER_KEYCLOAK-}" "${PG_PWD_KEYCLOAK-}" "${PG_DB_KEYCLOAK-}"
  ensure_pg_role_and_db "${PG_USER_AIRBYTE-}" "${PG_PWD_AIRBYTE-}" "${PG_DB_AIRBYTE-}"
  ensure_pg_role_and_db "${PG_USER_OM-}" "${PG_PWD_OM-}" "${PG_DB_OM-}"
  ensure_pg_role_and_db "${PG_USER_TEMPORAL-}" "${PG_PWD_TEMPORAL-}" "${PG_DB_TEMPORAL-}"
}
