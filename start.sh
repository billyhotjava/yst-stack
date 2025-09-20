#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
MODE="${1:-}"; SECRET="${2:-}"
usage(){ echo "Usage: $0 [single|ha2|cluster] [unified-password]"; }
pick_mode(){ echo "1) single  2) ha2  3) cluster"; read -rp "Choice: " c; case "$c" in 1) MODE=single;;2) MODE=ha2;;3) MODE=cluster;;*) exit 1;; esac; }
read_secret(){ while true; do read -rsp "Password: " p1; echo; read -rsp "Confirm: " p2; echo; [[ "$p1" == "$p2" ]] || { echo "Mismatch"; continue; }; [[ ${#p1} -ge 10 && "$p1" =~ [A-Z] && "$p1" =~ [a-z] && "$p1" =~ [0-9] && "$p1" =~ [^A-Za-z0-9] ]] || { echo "Weak"; continue; }; SECRET="$p1"; break; done; }
ensure_env(){ k="$1"; shift; v="$*"; if grep -qE "^${k}=" .env 2>/dev/null; then sed -i -E "s|^${k}=.*|${k}=${v}|g" .env; else echo "${k}=${v}" >> .env; fi; }
load_img_versions(){ conf="imgversion.conf"; [[ -f "$conf" ]] || return 0; while IFS='=' read -r k v; do [[ -z "${k// }" || "${k#\#}" != "$k" ]] && continue; v="$(echo "$v"|sed -E 's/^\s+|\s+$//g')"; ensure_env "$k" "$v"; done < <(grep -E '^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=' "$conf" || true); echo "[start.sh] loaded image versions"; }
generate_env_base(){ : "${BASE_DOMAIN:=yts.local}"; : "${TLS_PORT:=443}"; : "${KC_VERSION:=26.1}"; : "${KC_ADMIN:=admin}"; : "${KC_ADMIN_PWD:=${SECRET}}"; : "${KC_REALM:=yts}"; : "${MINIO_ROOT_USER:=minio}"; : "${MINIO_ROOT_PASSWORD:=${SECRET}}"; : "${S3_BUCKET:=yts-lake}"; : "${S3_REGION:=cn-local-1}"; : "${PG_SUPER_USER:=postgres}"; : "${PG_SUPER_PASSWORD:=${SECRET}#pg}"; : "${PG_PORT:=5432}"; : "${PG_DB_KEYCLOAK:=yts_keycloak}"; : "${PG_USER_KEYCLOAK:=yts_keycloak}"; : "${PG_PWD_KEYCLOAK:=${SECRET}}"; : "${PG_DB_AIRBYTE:=yts_airbyte}"; : "${PG_USER_AIRBYTE:=yts_airbyte}"; : "${PG_PWD_AIRBYTE:=${SECRET}}"; : "${PG_DB_OM:=yts_openmetadata}"; : "${PG_USER_OM:=yts_openmetadata}"; : "${PG_PWD_OM:=${SECRET}}"; : "${PG_DB_TEMPORAL:=yts_temporal}"; : "${PG_USER_TEMPORAL:=yts_temporal}"; : "${PG_PWD_TEMPORAL:=${SECRET}}";
cat > .env <<EOF
BASE_DOMAIN=${BASE_DOMAIN}
HOST_PORTAL=portal.${BASE_DOMAIN}
HOST_ADMIN=admin.${BASE_DOMAIN}
HOST_AI=ai.${BASE_DOMAIN}
HOST_ASSIST=assist.${BASE_DOMAIN}
HOST_SSO=sso.${BASE_DOMAIN}
HOST_MINIO=minio.${BASE_DOMAIN}
HOST_TRINO=trino.${BASE_DOMAIN}
HOST_AIRBYTE=airbyte.${BASE_DOMAIN}
HOST_META=meta.${BASE_DOMAIN}
TLS_PORT=${TLS_PORT}
KC_VERSION=${KC_VERSION}
KC_ADMIN=${KC_ADMIN}
KC_ADMIN_PWD=${KC_ADMIN_PWD}
KC_REALM=${KC_REALM}
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
S3_BUCKET=${S3_BUCKET}
S3_REGION=${S3_REGION}
PG_SUPER_USER=${PG_SUPER_USER}
PG_SUPER_PASSWORD=${PG_SUPER_PASSWORD}
PG_PORT=${PG_PORT}
PG_DB_KEYCLOAK=${PG_DB_KEYCLOAK}
PG_USER_KEYCLOAK=${PG_USER_KEYCLOAK}
PG_PWD_KEYCLOAK=${PG_PWD_KEYCLOAK}
PG_DB_AIRBYTE=${PG_DB_AIRBYTE}
PG_USER_AIRBYTE=${PG_USER_AIRBYTE}
PG_PWD_AIRBYTE=${PG_PWD_AIRBYTE}
PG_DB_OM=${PG_DB_OM}
PG_USER_OM=${PG_USER_OM}
PG_PWD_OM=${PG_PWD_OM}
PG_DB_TEMPORAL=${PG_DB_TEMPORAL}
PG_USER_TEMPORAL=${PG_USER_TEMPORAL}
PG_PWD_TEMPORAL=${PG_PWD_TEMPORAL}
EOF
}
write_pg_init_sql(){ mkdir -p postgres/init postgres/data data/minio openmetadata/es airbyte/workspace; chmod -R 777 postgres/data data/minio openmetadata/es airbyte/workspace; set -a; source .env; set +a; cat > postgres/init/10-init-users.sql <<SQL
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
SELECT pg_reload_conf();
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${PG_USER_KEYCLOAK}') THEN CREATE ROLE ${PG_USER_KEYCLOAK} LOGIN PASSWORD '${PG_PWD_KEYCLOAK}'; ELSE ALTER ROLE ${PG_USER_KEYCLOAK} WITH LOGIN PASSWORD '${PG_PWD_KEYCLOAK}'; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${PG_DB_KEYCLOAK}') THEN CREATE DATABASE ${PG_DB_KEYCLOAK} OWNER ${PG_USER_KEYCLOAK}; ELSE ALTER DATABASE ${PG_DB_KEYCLOAK} OWNER TO ${PG_USER_KEYCLOAK}; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${PG_USER_AIRBYTE}') THEN CREATE ROLE ${PG_USER_AIRBYTE} LOGIN PASSWORD '${PG_PWD_AIRBYTE}'; ELSE ALTER ROLE ${PG_USER_AIRBYTE} WITH LOGIN PASSWORD '${PG_PWD_AIRBYTE}'; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${PG_DB_AIRBYTE}') THEN CREATE DATABASE ${PG_DB_AIRBYTE} OWNER ${PG_USER_AIRBYTE}; ELSE ALTER DATABASE ${PG_DB_AIRBYTE} OWNER TO ${PG_USER_AIRBYTE}; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${PG_USER_OM}') THEN CREATE ROLE ${PG_USER_OM} LOGIN PASSWORD '${PG_PWD_OM}'; ELSE ALTER ROLE ${PG_USER_OM} WITH LOGIN PASSWORD '${PG_PWD_OM}'; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${PG_DB_OM}') THEN CREATE DATABASE ${PG_DB_OM} OWNER ${PG_USER_OM}; ELSE ALTER DATABASE ${PG_DB_OM} OWNER TO ${PG_USER_OM}; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${PG_USER_TEMPORAL}') THEN CREATE ROLE ${PG_USER_TEMPORAL} LOGIN PASSWORD '${PG_PWD_TEMPORAL}'; ELSE ALTER ROLE ${PG_USER_TEMPORAL} WITH LOGIN PASSWORD '${PG_PWD_TEMPORAL}'; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${PG_DB_TEMPORAL}') THEN CREATE DATABASE ${PG_DB_TEMPORAL} OWNER ${PG_USER_TEMPORAL}; ELSE ALTER DATABASE ${PG_DB_TEMPORAL} OWNER TO ${PG_USER_TEMPORAL}; END IF; END $$;
SQL
}
if [[ -z "${MODE}" ]]; then pick_mode; else case "$MODE" in single|ha2|cluster) ;; *) usage; exit 1;; esac; fi
if [[ -z "${SECRET}" ]]; then read_secret; else [[ ${#SECRET} -ge 10 && "$SECRET" =~ [A-Z] && "$SECRET" =~ [a-z] && "$SECRET" =~ [0-9] && "$SECRET" =~ [^A-Za-z0-9] ]] || { echo "Weak password"; exit 1; } fi
COMPOSE_FILE="docker-compose.yml"; PG_HOST="yts-pg"; PG_MODE="embedded"
case "$MODE" in single) ;; ha2) COMPOSE_FILE="docker-compose.ha2.yml"; PG_HOST="your-external-pg-host"; PG_MODE="external";; cluster) COMPOSE_FILE="docker-compose.cluster.yml"; PG_HOST="your-external-pg-host"; PG_MODE="external";; esac
generate_env_base; ensure_env PG_MODE "${PG_MODE}"; ensure_env PG_HOST "${PG_HOST}"
load_img_versions
mkdir -p tls; cat > tls/gen-certs.sh <<'SH'
#!/usr/bin/env bash
set -e
mkdir -p tls/certs
BASE_DOMAIN="${BASE_DOMAIN:-yts.local}"
if [[ -f tls/certs/server.crt && -f tls/certs/server.key ]]; then
  echo "[tls] cert exists, skip."
  exit 0
fi
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes   -keyout tls/certs/server.key -out tls/certs/server.crt   -subj "/CN=*.${BASE_DOMAIN}/O=YTS"   -addext "subjectAltName=DNS:*.${BASE_DOMAIN},DNS:${BASE_DOMAIN}"
echo "[tls] generated tls/certs/server.crt & server.key"
SH
chmod +x tls/gen-certs.sh
bash tls/gen-certs.sh || true
[[ "${PG_MODE}" == "embedded" ]] && write_pg_init_sql
if [[ ! -x "minio/init.sh" ]]; then
  mkdir -p minio
  cat > minio/init.sh <<'SH'
#!/bin/sh
set -e
mc alias set local http://yts-minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
if mc ls "local/${S3_BUCKET}" >/dev/null 2>&1; then
  echo "Bucket ${S3_BUCKET} already exists"
else
  echo "Creating bucket ${S3_BUCKET} ..."
  mc mb "local/${S3_BUCKET}"
fi
mc anonymous set download "local/${S3_BUCKET}" >/dev/null 2>&1 || true
echo "MinIO init done"
SH
  chmod +x minio/init.sh
fi
mkdir -p trino/catalog
[[ -f trino/catalog/hive.properties ]] || cat > trino/catalog/hive.properties <<'PROPS'
connector.name=hive
hive.metastore.uri=thrift://yts-metastore:9083
hive.s3.endpoint=http://yts-minio:9000
hive.s3.path-style-access=true
hive.s3.aws-access-key=${env:MINIO_ROOT_USER}
hive.s3.aws-secret-key=${env:MINIO_ROOT_PASSWORD}
hive.s3.ssl.enabled=false
hive.non-managed-table-writes-enabled=true
hive.storage-format=ORC
PROPS
echo "[start.sh] Starting with ${COMPOSE_FILE} ..."
if docker compose version >/dev/null 2>&1; then docker compose -f "${COMPOSE_FILE}" up -d
elif command -v docker-compose >/dev/null 2>&1; then docker-compose -f "${COMPOSE_FILE}" up -d
else echo "docker compose not found"; exit 1; fi
BASE_DOMAIN="$(grep '^BASE_DOMAIN=' .env | cut -d= -f2)"
for h in sso minio trino airbyte meta portal admin ai assist; do echo "https://${h}.${BASE_DOMAIN}"; done
