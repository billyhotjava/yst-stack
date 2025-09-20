#!/usr/bin/env bash
set -euo pipefail

psql=(psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB:-postgres}")

# Enforce SCRAM-SHA-256 for password encryption
"${psql[@]}" <<'SQL'
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
SELECT pg_reload_conf();
SQL

init_role_and_db() {
  local role="$1"
  local password="$2"
  local database="$3"

  if [[ -z "${role}" || -z "${password}" || -z "${database}" ]]; then
    echo "[yts-pg] Missing variables for role/database initialization, skip." >&2
    return 0
  fi

  "${psql[@]}" --set=role_name="${role}" --set=role_pwd="${password}" --set=db_name="${database}" <<'SQL'
DO $do$
DECLARE
  role_name text := :'role_name';
  role_pwd text := :'role_pwd';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', role_name, role_pwd);
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', role_name, role_pwd);
  END IF;
END
$do$;

DO $do$
DECLARE
  role_name text := :'role_name';
  db_name text := :'db_name';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = db_name) THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', db_name, role_name);
  ELSE
    EXECUTE format('ALTER DATABASE %I OWNER TO %I', db_name, role_name);
  END IF;
END
$do$;
SQL
}

init_role_and_db "${PG_USER_KEYCLOAK}" "${PG_PWD_KEYCLOAK}" "${PG_DB_KEYCLOAK}"
init_role_and_db "${PG_USER_AIRBYTE}" "${PG_PWD_AIRBYTE}" "${PG_DB_AIRBYTE}"
init_role_and_db "${PG_USER_OM}" "${PG_PWD_OM}" "${PG_DB_OM}"
init_role_and_db "${PG_USER_TEMPORAL}" "${PG_PWD_TEMPORAL}" "${PG_DB_TEMPORAL}"
