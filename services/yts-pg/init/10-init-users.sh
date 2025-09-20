#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/ensure-users.sh"

: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=postgres}"

psql=(psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}")

# Enforce SCRAM-SHA-256 for password encryption
"${psql[@]}" <<'SQL'
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
SELECT pg_reload_conf();
SQL

ensure_pg_roles
