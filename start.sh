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

prepare_data_dirs(){
  if [[ "${PG_MODE}" == "embedded" ]]; then
    mkdir -p postgres/init postgres/data
    chmod -R 777 postgres/data
  fi
  mkdir -p data/minio airbyte/workspace openmetadata/es openmetadata/es/certs observability/loki observability/prometheus-data observability/grafana
  chmod -R 777 data/minio airbyte/workspace || true
  chmod -R 777 openmetadata/es || true
  chmod -R 777 observability/loki observability/prometheus-data observability/grafana || true
}

generate_env_base(){
  : "${BASE_DOMAIN:=yts.local}"
  : "${TLS_PORT:=443}"
  : "${KC_VERSION:=26.1}"
  : "${KC_ADMIN:=admin}"
  : "${KC_ADMIN_PWD:=${SECRET}}"
  : "${KC_REALM:=yts}"
  : "${MINIO_ROOT_USER:=minio}"
  : "${MINIO_ROOT_PASSWORD:=${SECRET}}"
  : "${S3_BUCKET:=yts-lake}"
  : "${S3_REGION:=cn-local-1}"
  : "${PG_SUPER_USER:=postgres}"
  : "${PG_SUPER_PASSWORD:=${SECRET}}"
  : "${PG_PORT:=5432}"
  : "${PG_DB_KEYCLOAK:=yts_keycloak}"
  : "${PG_USER_KEYCLOAK:=yts_keycloak}"
  : "${PG_PWD_KEYCLOAK:=${SECRET}}"
  : "${PG_DB_AIRBYTE:=yts_airbyte}"
  : "${PG_USER_AIRBYTE:=yts_airbyte}"
  : "${PG_PWD_AIRBYTE:=${SECRET}}"
  : "${PG_DB_OM:=yts_openmetadata}"
  : "${PG_USER_OM:=yts_openmetadata}"
  : "${PG_PWD_OM:=${SECRET}}"
  : "${PG_DB_TEMPORAL:=yts_temporal}"
  : "${PG_USER_TEMPORAL:=yts_temporal}"
  : "${PG_PWD_TEMPORAL:=${SECRET}}"

  if [[ "${MODE}" == "single" ]]; then
    : "${TRAEFIK_DASHBOARD:=true}"
    : "${ENABLE_LOGGING_STACK:=false}"
    : "${ENABLE_MONITORING_STACK:=false}"
    : "${ELASTICSEARCH_SECURITY_ENABLED:=false}"
    : "${ELASTICSEARCH_HTTP_SSL_ENABLED:=false}"
  else
    : "${TRAEFIK_DASHBOARD:=false}"
    : "${ENABLE_LOGGING_STACK:=true}"
    : "${ENABLE_MONITORING_STACK:=true}"
    : "${ELASTICSEARCH_SECURITY_ENABLED:=true}"
    : "${ELASTICSEARCH_HTTP_SSL_ENABLED:=true}"
  fi

  : "${TRAEFIK_DASHBOARD_PORT:=8080}"
  : "${TRAEFIK_METRICS_PORT:=9100}"
  : "${ELASTICSEARCH_USERNAME:=elastic}"
  : "${ELASTIC_PASSWORD:=${SECRET}}"
  : "${ELASTICSEARCH_HTTP_SSL_KEY:=/usr/share/elasticsearch/config/certs/http.key}"
  : "${ELASTICSEARCH_HTTP_SSL_CERT:=/usr/share/elasticsearch/config/certs/http.crt}"
  : "${ELASTICSEARCH_HTTP_SSL_CA:=/usr/share/elasticsearch/config/certs/ca.crt}"
  : "${ELASTICSEARCH_VERIFY_CERTIFICATE:=$([[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]] && echo true || echo false)}"
  : "${ELASTICSEARCH_SCHEME:=$([[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]] && echo https || echo http)}"
  : "${OPENMETADATA_ELASTICSEARCH_CA:=/opt/openmetadata/certs/ca.crt}"
  : "${ELASTICSEARCH_HEALTHCHECK_URL:=${ELASTICSEARCH_SCHEME}://localhost:9200/_cluster/health}"
  if [[ "${ELASTICSEARCH_SECURITY_ENABLED}" == "true" ]]; then
    : "${ELASTICSEARCH_HEALTHCHECK_EXTRA_ARGS:=--user ${ELASTICSEARCH_USERNAME}:${ELASTIC_PASSWORD}}"
    if [[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]]; then
      ELASTICSEARCH_HEALTHCHECK_EXTRA_ARGS+=" --cacert ${ELASTICSEARCH_HTTP_SSL_CA}"
    fi
  else
    : "${ELASTICSEARCH_HEALTHCHECK_EXTRA_ARGS:=}"
  fi
  : "${GRAFANA_ADMIN_USER:=admin}"
  : "${GRAFANA_ADMIN_PASSWORD:=${SECRET}}"

  : "${HOST_PORTAL:=portal.${BASE_DOMAIN}}"
  : "${HOST_ADMIN:=admin.${BASE_DOMAIN}}"
  : "${HOST_AI:=ai.${BASE_DOMAIN}}"
  : "${HOST_ASSIST:=assist.${BASE_DOMAIN}}"
  : "${HOST_SSO:=sso.${BASE_DOMAIN}}"
  : "${HOST_MINIO:=minio.${BASE_DOMAIN}}"
  : "${HOST_TRINO:=trino.${BASE_DOMAIN}}"
  : "${HOST_AIRBYTE:=airbyte.${BASE_DOMAIN}}"
  : "${HOST_META:=meta.${BASE_DOMAIN}}"
  : "${HOST_TRAEFIK:=traefik.${BASE_DOMAIN}}"

  local compose_profiles=()
  [[ "${ENABLE_LOGGING_STACK}" == "true" ]] && compose_profiles+=("logging")
  [[ "${ENABLE_MONITORING_STACK}" == "true" ]] && compose_profiles+=("monitoring")
  local compose_profiles_value=""
  if ((${#compose_profiles[@]})); then
    compose_profiles_value="$(IFS=,; echo "${compose_profiles[*]}")"
  fi
  COMPOSE_PROFILES="${compose_profiles_value}"
  export COMPOSE_PROFILES

  cat > .env <<EOF
BASE_DOMAIN=${BASE_DOMAIN}
HOST_PORTAL=${HOST_PORTAL}
HOST_ADMIN=${HOST_ADMIN}
HOST_AI=${HOST_AI}
HOST_ASSIST=${HOST_ASSIST}
HOST_SSO=${HOST_SSO}
HOST_MINIO=${HOST_MINIO}
HOST_TRINO=${HOST_TRINO}
HOST_AIRBYTE=${HOST_AIRBYTE}
HOST_META=${HOST_META}
HOST_TRAEFIK=${HOST_TRAEFIK}
TLS_PORT=${TLS_PORT}
TRAEFIK_DASHBOARD=${TRAEFIK_DASHBOARD}
TRAEFIK_DASHBOARD_PORT=${TRAEFIK_DASHBOARD_PORT}
TRAEFIK_METRICS_PORT=${TRAEFIK_METRICS_PORT}
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
ENABLE_LOGGING_STACK=${ENABLE_LOGGING_STACK}
ENABLE_MONITORING_STACK=${ENABLE_MONITORING_STACK}
COMPOSE_PROFILES=${COMPOSE_PROFILES}
ELASTICSEARCH_SECURITY_ENABLED=${ELASTICSEARCH_SECURITY_ENABLED}
ELASTICSEARCH_HTTP_SSL_ENABLED=${ELASTICSEARCH_HTTP_SSL_ENABLED}
ELASTICSEARCH_HTTP_SSL_KEY=${ELASTICSEARCH_HTTP_SSL_KEY}
ELASTICSEARCH_HTTP_SSL_CERT=${ELASTICSEARCH_HTTP_SSL_CERT}
ELASTICSEARCH_HTTP_SSL_CA=${ELASTICSEARCH_HTTP_SSL_CA}
ELASTICSEARCH_SCHEME=${ELASTICSEARCH_SCHEME}
ELASTICSEARCH_VERIFY_CERTIFICATE=${ELASTICSEARCH_VERIFY_CERTIFICATE}
ELASTICSEARCH_HEALTHCHECK_URL=${ELASTICSEARCH_HEALTHCHECK_URL}
ELASTICSEARCH_HEALTHCHECK_EXTRA_ARGS="${ELASTICSEARCH_HEALTHCHECK_EXTRA_ARGS}"
ELASTICSEARCH_USERNAME=${ELASTICSEARCH_USERNAME}
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
OPENMETADATA_ELASTICSEARCH_CA=${OPENMETADATA_ELASTICSEARCH_CA}
GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
EOF
}
write_pg_init_sql(){
  set -a
  source .env
  set +a
  cat > postgres/init/10-init-users.sql <<SQL
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
if [[ "${PG_MODE}" == "external" && "${PG_HOST}" == "your-external-pg-host" ]]; then
  if [[ -t 0 ]]; then
    read -rp "[start.sh] Enter the hostname or IP for the external PostgreSQL instance: " input_pg_host
    if [[ -n "${input_pg_host}" ]]; then
      PG_HOST="${input_pg_host}"
    fi
  fi
  if [[ "${PG_HOST}" == "your-external-pg-host" ]]; then
    echo "[start.sh] WARNING: PG_HOST is still set to 'your-external-pg-host'. Update it in .env before starting services." >&2
  fi
fi
generate_env_base; ensure_env PG_MODE "${PG_MODE}"; ensure_env PG_HOST "${PG_HOST}"
load_img_versions
prepare_data_dirs
if [[ "${MODE}" != "single" && "${ELASTICSEARCH_SECURITY_ENABLED}" != "true" ]]; then
  echo "[start.sh] ERROR: Production modes require ELASTICSEARCH_SECURITY_ENABLED=true." >&2
  exit 1
fi
if [[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]]; then
  missing_cert=0
  for cert_file in http.key http.crt ca.crt; do
    if [[ ! -f "openmetadata/es/certs/${cert_file}" ]]; then
      echo "[start.sh] ERROR: Missing openmetadata/es/certs/${cert_file} required when Elasticsearch TLS is enabled." >&2
      missing_cert=1
    fi
  done
  if (( missing_cert )); then
    exit 1
  fi
fi
mkdir -p tls
cat > tls/gen-certs.sh <<'SH'
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
if [[ "${MODE}" == "single" ]]; then
  bash tls/gen-certs.sh || true
else
  if [[ ! -f tls/certs/server.crt || ! -f tls/certs/server.key ]]; then
    echo "[start.sh] ERROR: Production mode requires a CA-issued TLS certificate at tls/certs/server.crt and tls/certs/server.key." >&2
    exit 1
  fi
fi
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
TRAEFIK_DASHBOARD_ENABLED="$(grep '^TRAEFIK_DASHBOARD=' .env | cut -d= -f2)"
if [[ "${TRAEFIK_DASHBOARD_ENABLED}" == "true" ]]; then
  HOST_TRAEFIK_URL="$(grep '^HOST_TRAEFIK=' .env | cut -d= -f2)"
  TRAEFIK_DASHBOARD_PORT_VALUE="$(grep '^TRAEFIK_DASHBOARD_PORT=' .env | cut -d= -f2)"
  echo "https://${HOST_TRAEFIK_URL} (Traefik dashboard)"
  echo "http://localhost:${TRAEFIK_DASHBOARD_PORT_VALUE} (local Traefik dashboard via --api.insecure)"
fi
