#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
MODE=""
SECRET=""
BASE_DOMAIN_ARG=""

usage(){ echo "Usage: $0 [single|ha2|cluster] [unified-password] [base-domain]"; }

looks_like_domain(){
  local candidate="${1:-}"
  [[ "$candidate" == *.* && "$candidate" =~ ^[A-Za-z0-9.-]+$ ]]
}

normalize_base_domain(){
  local candidate="${1:-}"
  candidate="${candidate#http://}"
  candidate="${candidate#https://}"
  candidate="${candidate#//}"
  candidate="${candidate%%/*}"
  candidate="${candidate#.}"
  candidate="${candidate%.}"
  candidate="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$candidate"
}

validate_base_domain(){
  local candidate="${1:-}"
  [[ -n "$candidate" ]] || return 1
  [[ "$candidate" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

prompt_base_domain(){
  local default_value="${1:-yts.local}"
  local input=""
  while true; do
    if ! read -rp "[init.sh] Base domain [${default_value}]: " input; then
      input="${default_value}"
    fi
    if [[ -z "$input" ]]; then
      input="${default_value}"
    fi
    input="$(normalize_base_domain "$input")"
    if validate_base_domain "$input"; then
      BASE_DOMAIN="$input"
      return
    fi
    echo "[init.sh] Invalid base domain. Use letters, digits, hyphen, and dots, and include at least one dot." >&2
  done
}

#------------Excute functions----------------
pick_mode(){ echo "1) single  2) ha2  3) cluster"; read -rp "Choice: " c; case "$c" in 1) MODE=single;;2) MODE=ha2;;3) MODE=cluster;;*) exit 1;; esac; }
read_secret(){ while true; do read -rsp "Password: " p1; echo; read -rsp "Confirm: " p2; echo; [[ "$p1" == "$p2" ]] || { echo "Mismatch"; continue; }; [[ ${#p1} -ge 10 && "$p1" =~ [A-Z] && "$p1" =~ [a-z] && "$p1" =~ [0-9] && "$p1" =~ [^A-Za-z0-9] ]] || { echo "Weak"; continue; }; SECRET="$p1"; break; done; }
ensure_env(){ k="$1"; shift; v="$*"; if grep -qE "^${k}=" .env 2>/dev/null; then sed -i -E "s|^${k}=.*|${k}=${v}|g" .env; else echo "${k}=${v}" >> .env; fi; }
load_img_versions(){ conf="imgversion.conf"; [[ -f "$conf" ]] || return 0; while IFS='=' read -r k v; do [[ -z "${k// }" || "${k#\#}" != "$k" ]] && continue; v="$(echo "$v"|sed -E 's/^\s+|\s+$//g')"; ensure_env "$k" "$v"; done < <(grep -E '^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=' "$conf" || true); echo "[init.sh] loaded image versions"; }

fix_pg_permissions(){
  if [[ "${PG_MODE:-}" != "embedded" ]]; then
    return
  fi

  local pg_dir="services/yts-pg/data"
  mkdir -p "${pg_dir}"

  local pg_runtime_uid="${PG_RUNTIME_UID:-999}"
  local pg_runtime_gid="${PG_RUNTIME_GID:-${pg_runtime_uid}}"

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -R -m u:"${pg_runtime_uid}":rwx "${pg_dir}" 2>/dev/null || true
    setfacl -R -d -m u:"${pg_runtime_uid}":rwx "${pg_dir}" 2>/dev/null || true
  else
    echo "[init.sh] WARNING: setfacl not found, falling back to chmod 777 on Postgres data directory." >&2
    chmod -R 777 "${pg_dir}" 2>/dev/null || true
  fi

  chown -R "${pg_runtime_uid}:${pg_runtime_gid}" "${pg_dir}" 2>/dev/null || true
}

prepare_data_dirs(){
  fix_pg_permissions

  local -a data_dirs=(
    "services/certs"
    "services/yts-minio/data"
    "services/yts-minio-init/data"
    "services/yts-ranger/admin/conf"
    "services/yts-ranger/admin/data"
    "services/yts-ranger/admin/logs"
    "services/yts-airbyte-server/data/workspace"
    "services/yts-airbyte-worker/data"
    "services/yts-airbyte-temporal/data"
    "services/yts-om-es/data"
    "services/yts-om-es/data/certs"
    "services/yts-openmetadata-server/data"
    "services/yts-llm/data"
    "services/yts-ai-gateway/data"
    "services/yts-dtadminui/data"
    "services/yts-dtadmin/data"
    "services/yts-dbt/logs"
    "services/yts-doris/fe/meta"
    "services/yts-doris/fe/log"
    "services/yts-doris/be/storage"
    "services/yts-doris/be/log"
    "services/yts-doris/broker/log"
    "services/yts-loki/data"
    "services/yts-promtail/data"
    "services/yts-prometheus/data"
    "services/yts-grafana/data"
    "services/yts-cadvisor/data"
  )

  local dir
  for dir in "${data_dirs[@]}"; do
    mkdir -p "${dir}"
  done

  chmod -R 777 services/yts-minio/data services/yts-airbyte-server/data || true
  chmod -R 777 services/yts-ranger/admin/data services/yts-ranger/admin/logs || true
  chmod -R 777 services/yts-om-es/data || true
  chmod -R 777 services/yts-doris/be/storage services/yts-doris/be/log services/yts-doris/fe/meta services/yts-doris/fe/log || true
  chmod -R 777 services/yts-loki/data services/yts-prometheus/data services/yts-grafana/data || true
}

ensure_elasticsearch_tls_assets(){
  if [[ "${ELASTICSEARCH_HTTP_SSL_ENABLED:-}" != "true" ]]; then
    return
  fi

  local cert_dir="${ELASTICSEARCH_CERTS_DIR}"
  [[ -n "${cert_dir}" ]] || return
  mkdir -p "${cert_dir}"

  local ca_key="${cert_dir}/ca.key"
  local ca_cert="${cert_dir}/ca.crt"
  local http_key="${cert_dir}/http.key"
  local http_cert="${cert_dir}/http.crt"

  if [[ -f "${http_key}" && -f "${http_cert}" && -f "${ca_cert}" ]]; then
    return
  fi

  if [[ -f "${http_key}" || -f "${http_cert}" || -f "${ca_cert}" || -f "${ca_key}" ]]; then
    echo "[init.sh] detected partial Elasticsearch TLS assets under ${cert_dir}; provide the remaining files or remove them before rerunning." >&2
    return
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "[init.sh] ERROR: openssl not found; place TLS assets under ${cert_dir} or install openssl." >&2
    exit 1
  fi

  echo "[init.sh] generating self-signed Elasticsearch TLS assets under ${cert_dir}" >&2

  openssl genrsa -out "${ca_key}" 4096 >/dev/null 2>&1
  openssl req -x509 -new -key "${ca_key}" -sha256 -days 825 -subj "/CN=Elasticsearch CA" -out "${ca_cert}" >/dev/null 2>&1

  openssl genrsa -out "${http_key}" 2048 >/dev/null 2>&1
  local ext_file="${cert_dir}/http.ext"
  cat > "${ext_file}" <<'EOF'
subjectAltName = DNS:localhost,IP:127.0.0.1
keyUsage = critical,Digital Signature,Key Encipherment
extendedKeyUsage = serverAuth
EOF
  local csr_file="${cert_dir}/http.csr"
  openssl req -new -key "${http_key}" -subj "/CN=elasticsearch" -out "${csr_file}" >/dev/null 2>&1
  openssl x509 -req -in "${csr_file}" -CA "${ca_cert}" -CAkey "${ca_key}" -CAcreateserial -out "${http_cert}" -days 825 -sha256 -extfile "${ext_file}" >/dev/null 2>&1

  rm -f "${csr_file}" "${ext_file}"
  chmod 600 "${http_key}" "${ca_key}" 2>/dev/null || true
  chmod 644 "${http_cert}" "${ca_cert}" 2>/dev/null || true
}

generate_env_base(){
  : "${BASE_DOMAIN:=yts.local}"
  : "${TLS_PORT:=443}"
  : "${KC_VERSION:=26.3.4}"
  : "${KC_ADMIN:=admin}"
  : "${KC_ADMIN_PWD:=${SECRET}}"
  : "${KC_REALM:=yts}"
  : "${KC_PROXY:=edge}"
  : "${KC_HOSTNAME:=sso.${BASE_DOMAIN}}"
  : "${KC_HOSTNAME_PORT:=${TLS_PORT}}"
  : "${KC_HOSTNAME_STRICT:=true}"
  : "${KC_HOSTNAME_STRICT_HTTPS:=true}"
  : "${KC_HTTP_ENABLED:=true}"
  : "${KC_FEATURES:=scripts}"
  : "${MINIO_ROOT_USER:=minio}"
  : "${MINIO_ROOT_PASSWORD:=${SECRET}}"
  : "${S3_BUCKET:=yts-lake}"
  : "${S3_REGION:=cn-local-1}"
  : "${AIRBYTE_SECRET_PERSISTENCE:=testing_config_db_table}"
  : "${AIRBYTE_MICRONAUT_ENVIRONMENTS:=control-plane,oss}"
  : "${AIRBYTE_ENTERPRISE_SOURCE_STUBS_URL:=https://connectors.airbyte.com/files/enterprise-source-stubs.json}"
  : "${AIRBYTE_ENTERPRISE_DESTINATION_STUBS_URL:=https://connectors.airbyte.com/files/enterprise-destination-stubs.json}"
  : "${AIRBYTE_FLYWAY_CONFIGS_MINIMUM_MIGRATION_VERSION:=0.50.3}"
  : "${AIRBYTE_FLYWAY_JOBS_MINIMUM_MIGRATION_VERSION:=0.50.3}"
  : "${AIRBYTE_WORKER_ENVIRONMENT:=DOCKER}"
  : "${AIRBYTE_JOBS_KUBE_NAMESPACE:=default}"
  # Ensure .env is sourced before using IMAGE_AIRBYTE_SERVER
  if [ -f .env ]; then
    set -a
    . ./.env
    set +a
  fi
  local airbyte_image_tag="${IMAGE_AIRBYTE_SERVER:-}"
  if [[ -z "${airbyte_image_tag}" && -f imgversion.conf ]]; then
    airbyte_image_tag="$(grep -E '^IMAGE_AIRBYTE_SERVER=' imgversion.conf | head -n1 | cut -d= -f2-)"
  fi
  if [[ -n "${airbyte_image_tag}" ]]; then
    airbyte_image_tag="${airbyte_image_tag##*:}"
  fi
  : "${AIRBYTE_VERSION:=${airbyte_image_tag:-1.8.2}}"
  : "${PG_SUPER_USER:=postgres}"
  : "${PG_SUPER_PASSWORD:=${SECRET}}"
  : "${PG_PORT:=5432}"
  : "${PG_DB_KEYCLOAK:=yts_keycloak}"
  : "${PG_USER_KEYCLOAK:=yts_keycloak}"
  : "${PG_PWD_KEYCLOAK:=${SECRET}}"
  : "${PG_DB_AIRBYTE:=yts_airbyte}"
  : "${PG_USER_AIRBYTE:=yts_airbyte}"
  : "${PG_PWD_AIRBYTE:=${SECRET}}"
  : "${PG_DB_AIRBYTE_JOBS:=yts_airbyte_jobs}"
  : "${PG_USER_AIRBYTE_JOBS:=${PG_USER_AIRBYTE}}"
  : "${PG_PWD_AIRBYTE_JOBS:=${PG_PWD_AIRBYTE}}"
  : "${PG_DB_OM:=yts_openmetadata}"
  : "${PG_USER_OM:=yts_openmetadata}"
  : "${PG_PWD_OM:=${SECRET}}"
  : "${PG_DB_TEMPORAL:=yts_temporal}"
  : "${PG_USER_TEMPORAL:=yts_temporal}"
  : "${PG_PWD_TEMPORAL:=${SECRET}}"
  : "${PG_DB_TEMPORAL_VISIBILITY:=yts_temporal_visibility}"
  : "${PG_DB_RANGER:=yts_ranger}"
  : "${PG_USER_RANGER:=yts_ranger}"
  : "${PG_PWD_RANGER:=${SECRET}}"
  : "${PG_DB_RANGER_AUDIT:=yts_ranger_audit}"
  : "${PG_USER_RANGER_AUDIT:=${PG_USER_RANGER}}"
  : "${PG_PWD_RANGER_AUDIT:=${PG_PWD_RANGER}}"

  : "${ELASTICSEARCH_CERTS_DIR:=services/yts-om-es/data/certs}"
  local es_container_certs_dir="/usr/share/elasticsearch/config/certs"

  if [[ "${MODE}" == "single" ]]; then
    : "${TRAEFIK_DASHBOARD:=true}"
    : "${ENABLE_LOGGING_STACK:=false}"
    : "${ENABLE_MONITORING_STACK:=false}"
  else
    : "${TRAEFIK_DASHBOARD:=false}"
    : "${ENABLE_LOGGING_STACK:=true}"
    : "${ENABLE_MONITORING_STACK:=true}"
  fi

  # Force Elasticsearch to run with TLS (HTTPS) and X-Pack security enabled.
  ELASTICSEARCH_SECURITY_ENABLED="true"
  ELASTICSEARCH_HTTP_SSL_ENABLED="true"

  : "${TRAEFIK_DASHBOARD_PORT:=8080}"
  : "${TRAEFIK_METRICS_PORT:=9100}"
  : "${TRAEFIK_TLS_PORT:=443}"
  : "${TRAEFIK_TLS_ENTRYPOINT:=websecure}"
  : "${TRAEFIK_ENABLE_PING:=true}"   # 想用 `traefik healthcheck` 时为 true
  : "${ELASTICSEARCH_USERNAME:=elastic}"
  : "${ELASTIC_PASSWORD:=${SECRET}}"
  if [[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]]; then
    : "${ELASTICSEARCH_HTTP_SSL_KEY:=${es_container_certs_dir}/http.key}"
    : "${ELASTICSEARCH_HTTP_SSL_CERT:=${es_container_certs_dir}/http.crt}"
    : "${ELASTICSEARCH_HTTP_SSL_CA:=${es_container_certs_dir}/ca.crt}"
    : "${OPENMETADATA_ELASTICSEARCH_CA:=/opt/openmetadata/certs/ca.crt}"
  else
    : "${ELASTICSEARCH_HTTP_SSL_KEY:=}"
    : "${ELASTICSEARCH_HTTP_SSL_CERT:=}"
    : "${ELASTICSEARCH_HTTP_SSL_CA:=}"
    : "${OPENMETADATA_ELASTICSEARCH_CA:=}"
  fi
  : "${ELASTICSEARCH_VERIFY_CERTIFICATE:=$([[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]] && echo true || echo false)}"
  : "${ELASTICSEARCH_SCHEME:=$([[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]] && echo https || echo http)}"
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

  HOST_PORTAL="portal.${BASE_DOMAIN}"
  HOST_ADMIN="admin.${BASE_DOMAIN}"
  HOST_AI="ai.${BASE_DOMAIN}"
  HOST_ASSIST="assist.${BASE_DOMAIN}"
  HOST_SSO="sso.${BASE_DOMAIN}"
  HOST_MINIO="minio.${BASE_DOMAIN}"
  HOST_TRINO="trino.${BASE_DOMAIN}"
  HOST_AIRBYTE="airbyte.${BASE_DOMAIN}"
  HOST_META="meta.${BASE_DOMAIN}"
  HOST_TRAEFIK="traefik.${BASE_DOMAIN}"
  HOST_RANGER="ranger.${BASE_DOMAIN}"
  HOST_DBT="dbt.${BASE_DOMAIN}"
  HOST_DORIS="doris.${BASE_DOMAIN}"
  HOST_NESSIE="nessie.${BASE_DOMAIN}"
  : "${DTADMIN_API_PORT:=8080}"
  : "${DTADMIN_DB_NAME:=yts_dtadmin}"
  : "${DTADMIN_DB_USER:=yts_dtadmin}"
  : "${DTADMIN_DB_PASSWORD:=${SECRET}}"

  : "${OLLAMA_MODEL:=llama3:8b}"
  : "${OLLAMA_NUM_PARALLEL:=1}"
  : "${OLLAMA_KEEP_ALIVE:=5m}"

  : "${DBT_RPC_PORT:=8580}"
  : "${DBT_TRINO_HOST:=yts-trino}"
  : "${DBT_TRINO_PORT:=8080}"
  : "${DBT_TRINO_CATALOG:=doris}"
  : "${DBT_TRINO_SCHEMA:=analytics}"
  : "${DBT_TRINO_USER:=dbt}"
  : "${DBT_TRINO_PASSWORD:=}"
  : "${DBT_TRINO_HTTP_SCHEME:=http}"

  : "${DORIS_HTTP_PORT:=8030}"
  : "${DORIS_MYSQL_PORT:=9030}"
  : "${DORIS_FE_QUERY_PORT:=${DORIS_MYSQL_PORT}}"
  : "${DORIS_FE_RPC_PORT:=9020}"
  : "${DORIS_FE_EDIT_LOG_PORT:=9010}"
  : "${DORIS_BE_WEB_PORT:=8040}"
  : "${DORIS_BE_HEARTBEAT_PORT:=9050}"
  : "${DORIS_BE_BRPC_PORT:=9060}"
  : "${DORIS_BROKER_PORT:=8000}"
  : "${RANGER_ADMIN_USER:=admin}"
  : "${RANGER_ADMIN_PASSWORD:=${SECRET}}"
  : "${RANGER_SERVICE_TRINO:=yts_trino}"

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
HOST_RANGER=${HOST_RANGER}
HOST_DBT=${HOST_DBT}
HOST_DORIS=${HOST_DORIS}
HOST_NESSIE=${HOST_NESSIE}
TLS_PORT=${TLS_PORT}
TRAEFIK_DASHBOARD=${TRAEFIK_DASHBOARD}
TRAEFIK_DASHBOARD_PORT=${TRAEFIK_DASHBOARD_PORT}
TRAEFIK_METRICS_PORT=${TRAEFIK_METRICS_PORT}
TRAEFIK_TLS_PORT=${TRAEFIK_TLS_PORT}
TRAEFIK_TLS_ENTRYPOINT=${TRAEFIK_TLS_ENTRYPOINT}
TRAEFIK_ENABLE_PING=${TRAEFIK_ENABLE_PING}
KC_VERSION=${KC_VERSION}
KC_ADMIN=${KC_ADMIN}
KC_ADMIN_PWD=${KC_ADMIN_PWD}
KC_REALM=${KC_REALM}
KC_HOSTNAME=${KC_HOSTNAME}
KC_HOSTNAME_PORT=${KC_HOSTNAME_PORT}
KC_HOSTNAME_URL=https://${KC_HOSTNAME}
KC_HOSTNAME_STRICT=${KC_HOSTNAME_STRICT}
KC_HOSTNAME_STRICT_HTTPS=${KC_HOSTNAME_STRICT_HTTPS}
KC_HTTP_ENABLED=${KC_HTTP_ENABLED}
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
S3_BUCKET=${S3_BUCKET}
S3_REGION=${S3_REGION}
AIRBYTE_SECRET_PERSISTENCE=${AIRBYTE_SECRET_PERSISTENCE}
AIRBYTE_MICRONAUT_ENVIRONMENTS=${AIRBYTE_MICRONAUT_ENVIRONMENTS}
AIRBYTE_ENTERPRISE_SOURCE_STUBS_URL=${AIRBYTE_ENTERPRISE_SOURCE_STUBS_URL}
AIRBYTE_ENTERPRISE_DESTINATION_STUBS_URL=${AIRBYTE_ENTERPRISE_DESTINATION_STUBS_URL}
AIRBYTE_FLYWAY_CONFIGS_MINIMUM_MIGRATION_VERSION=${AIRBYTE_FLYWAY_CONFIGS_MINIMUM_MIGRATION_VERSION}
AIRBYTE_FLYWAY_JOBS_MINIMUM_MIGRATION_VERSION=${AIRBYTE_FLYWAY_JOBS_MINIMUM_MIGRATION_VERSION}
AIRBYTE_VERSION=${AIRBYTE_VERSION}
AIRBYTE_WORKER_ENVIRONMENT=${AIRBYTE_WORKER_ENVIRONMENT}
AIRBYTE_JOBS_KUBE_NAMESPACE=${AIRBYTE_JOBS_KUBE_NAMESPACE}
PG_SUPER_USER=${PG_SUPER_USER}
PG_SUPER_PASSWORD=${PG_SUPER_PASSWORD}
PG_PORT=${PG_PORT}
PG_DB_KEYCLOAK=${PG_DB_KEYCLOAK}
PG_USER_KEYCLOAK=${PG_USER_KEYCLOAK}
PG_PWD_KEYCLOAK=${PG_PWD_KEYCLOAK}
PG_DB_AIRBYTE=${PG_DB_AIRBYTE}
PG_USER_AIRBYTE=${PG_USER_AIRBYTE}
PG_PWD_AIRBYTE=${PG_PWD_AIRBYTE}
PG_DB_AIRBYTE_JOBS=${PG_DB_AIRBYTE_JOBS}
PG_USER_AIRBYTE_JOBS=${PG_USER_AIRBYTE_JOBS}
PG_PWD_AIRBYTE_JOBS=${PG_PWD_AIRBYTE_JOBS}
PG_DB_OM=${PG_DB_OM}
PG_USER_OM=${PG_USER_OM}
PG_PWD_OM=${PG_PWD_OM}
PG_DB_TEMPORAL=${PG_DB_TEMPORAL}
PG_USER_TEMPORAL=${PG_USER_TEMPORAL}
PG_PWD_TEMPORAL=${PG_PWD_TEMPORAL}
PG_DB_TEMPORAL_VISIBILITY=${PG_DB_TEMPORAL_VISIBILITY}
PG_DB_RANGER=${PG_DB_RANGER}
PG_USER_RANGER=${PG_USER_RANGER}
PG_PWD_RANGER=${PG_PWD_RANGER}
PG_DB_RANGER_AUDIT=${PG_DB_RANGER_AUDIT}
PG_USER_RANGER_AUDIT=${PG_USER_RANGER_AUDIT}
PG_PWD_RANGER_AUDIT=${PG_PWD_RANGER_AUDIT}
RANGER_ADMIN_USER=${RANGER_ADMIN_USER}
RANGER_ADMIN_PASSWORD=${RANGER_ADMIN_PASSWORD}
RANGER_SERVICE_TRINO=${RANGER_SERVICE_TRINO}
DTADMIN_API_PORT=${DTADMIN_API_PORT}
DTADMIN_DB_NAME=${DTADMIN_DB_NAME}
DTADMIN_DB_USER=${DTADMIN_DB_USER}
DTADMIN_DB_PASSWORD=${DTADMIN_DB_PASSWORD}
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
ELASTICSEARCH_CERTS_DIR=${ELASTICSEARCH_CERTS_DIR}
OPENMETADATA_ELASTICSEARCH_CA=${OPENMETADATA_ELASTICSEARCH_CA}
GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
DBT_RPC_PORT=${DBT_RPC_PORT}
DBT_TRINO_HOST=${DBT_TRINO_HOST}
DBT_TRINO_PORT=${DBT_TRINO_PORT}
DBT_TRINO_CATALOG=${DBT_TRINO_CATALOG}
DBT_TRINO_SCHEMA=${DBT_TRINO_SCHEMA}
DBT_TRINO_USER=${DBT_TRINO_USER}
DBT_TRINO_PASSWORD=${DBT_TRINO_PASSWORD}
DBT_TRINO_HTTP_SCHEME=${DBT_TRINO_HTTP_SCHEME}
DORIS_HTTP_PORT=${DORIS_HTTP_PORT}
DORIS_MYSQL_PORT=${DORIS_MYSQL_PORT}
DORIS_FE_QUERY_PORT=${DORIS_FE_QUERY_PORT}
DORIS_FE_RPC_PORT=${DORIS_FE_RPC_PORT}
DORIS_FE_EDIT_LOG_PORT=${DORIS_FE_EDIT_LOG_PORT}
DORIS_BE_WEB_PORT=${DORIS_BE_WEB_PORT}
DORIS_BE_HEARTBEAT_PORT=${DORIS_BE_HEARTBEAT_PORT}
DORIS_BE_BRPC_PORT=${DORIS_BE_BRPC_PORT}
DORIS_BROKER_PORT=${DORIS_BROKER_PORT}
OLLAMA_MODEL=${OLLAMA_MODEL}
OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}
OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
EOF
}

while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --password)
      shift
      if (($# == 0)); then
        echo "[init.sh] ERROR: --password requires a value." >&2
        exit 1
      fi
      SECRET="$1"
      ;;
    --base-domain)
      shift
      if (($# == 0)); then
        echo "[init.sh] ERROR: --base-domain requires a value." >&2
        exit 1
      fi
      if [[ -n "$BASE_DOMAIN_ARG" ]]; then
        echo "[init.sh] ERROR: base domain already provided as '${BASE_DOMAIN_ARG}'." >&2
        exit 1
      fi
      BASE_DOMAIN_ARG="$1"
      ;;
    single|ha2|cluster)
      if [[ -n "$MODE" ]]; then
        echo "[init.sh] ERROR: deployment mode already specified as '${MODE}'." >&2
        exit 1
      fi
      MODE="$1"
      ;;
    *)
      if [[ -z "$BASE_DOMAIN_ARG" ]] && looks_like_domain "$1"; then
        BASE_DOMAIN_ARG="$1"
      elif [[ -z "$SECRET" ]]; then
        SECRET="$1"
      else
        echo "[init.sh] ERROR: unexpected argument '$1'." >&2
        usage
        exit 1
      fi
      ;;
  esac
  shift
done

BASE_DOMAIN="${BASE_DOMAIN:-}"
if [[ -n "$BASE_DOMAIN_ARG" ]]; then
  BASE_DOMAIN="$(normalize_base_domain "$BASE_DOMAIN_ARG")"
fi

if [[ -z "$BASE_DOMAIN" && -f .env ]]; then
  existing_base_domain="$(grep -E '^BASE_DOMAIN=' .env | head -n1 | cut -d= -f2- | tr -d '\r')"
  if [[ -n "${existing_base_domain}" ]]; then
    BASE_DOMAIN="$(normalize_base_domain "${existing_base_domain}")"
  fi
fi

DEFAULT_BASE_DOMAIN="${BASE_DOMAIN:-yts.local}"
DEFAULT_BASE_DOMAIN="$(normalize_base_domain "$DEFAULT_BASE_DOMAIN")"

if [[ -z "$BASE_DOMAIN" ]]; then
  if [[ -t 0 ]]; then
    prompt_base_domain "$DEFAULT_BASE_DOMAIN"
  else
    BASE_DOMAIN="$DEFAULT_BASE_DOMAIN"
  fi
fi

BASE_DOMAIN="$(normalize_base_domain "$BASE_DOMAIN")"
if ! validate_base_domain "$BASE_DOMAIN"; then
  echo "[init.sh] ERROR: invalid base domain '${BASE_DOMAIN}'." >&2
  exit 1
fi

if [[ -z "${MODE}" ]]; then pick_mode; else case "$MODE" in single|ha2|cluster) ;; *) usage; exit 1;; esac; fi
if [[ -z "${SECRET}" ]]; then read_secret; else [[ ${#SECRET} -ge 10 && "$SECRET" =~ [A-Z] && "$SECRET" =~ [a-z] && "$SECRET" =~ [0-9] && "$SECRET" =~ [^A-Za-z0-9] ]] || { echo "Weak password"; exit 1; } fi

PG_MODE="${PG_MODE:-}"
PG_HOST="${PG_HOST:-}"
COMPOSE_FILE="docker-compose.yml"

case "$MODE" in
  single)
    COMPOSE_FILE="docker-compose.yml"
    PG_MODE="${PG_MODE:-embedded}"
    PG_HOST="${PG_HOST:-yts-pg}"
    ;;
  ha2)
    COMPOSE_FILE="docker-compose.ha2.yml"
    PG_MODE="${PG_MODE:-external}"
    PG_HOST="${PG_HOST:-your-external-pg-host}"
    ;;
  cluster)
    COMPOSE_FILE="docker-compose.cluster.yml"
    PG_MODE="${PG_MODE:-external}"
    PG_HOST="${PG_HOST:-your-external-pg-host}"
    ;;
esac
if [[ "${PG_MODE}" == "external" && "${PG_HOST}" == "your-external-pg-host" ]]; then
  if [[ -t 0 ]]; then
    read -rp "[init.sh] Enter the hostname or IP for the external PostgreSQL instance: " input_pg_host
    if [[ -n "${input_pg_host}" ]]; then
      PG_HOST="${input_pg_host}"
    fi
  fi
  if [[ "${PG_HOST}" == "your-external-pg-host" ]]; then
    echo "[init.sh] WARNING: PG_HOST is still set to 'your-external-pg-host'. Update it in .env before starting services." >&2
  fi
fi
generate_env_base; ensure_env PG_MODE "${PG_MODE}"; ensure_env PG_HOST "${PG_HOST}"
load_img_versions
prepare_data_dirs
if [[ -n "${MODE}" ]]; then
  ensure_env DEPLOY_MODE "${MODE}"
fi
ensure_elasticsearch_tls_assets
if [[ "${MODE}" != "single" && "${ELASTICSEARCH_SECURITY_ENABLED}" != "true" ]]; then
  echo "[init.sh] ERROR: Production modes require ELASTICSEARCH_SECURITY_ENABLED=true." >&2
  exit 1
fi
if [[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]]; then
  missing_cert=0
  for cert_file in http.key http.crt ca.crt; do
    if [[ ! -f "${ELASTICSEARCH_CERTS_DIR}/${cert_file}" ]]; then
      echo "[init.sh] ERROR: Missing ${ELASTICSEARCH_CERTS_DIR}/${cert_file} required when Elasticsearch TLS is enabled." >&2
      missing_cert=1
    fi
  done
  if (( missing_cert )); then
    exit 1
  fi
fi
if [[ "${MODE}" == "single" ]]; then
  BASE_DOMAIN="${BASE_DOMAIN}" bash services/certs/gen-certs.sh || true
else
  if [[ ! -f services/certs/server.crt || ! -f services/certs/server.key ]]; then
    echo "[init.sh] ERROR: Production mode requires a CA-issued TLS certificate at services/certs/server.crt and services/certs/server.key." >&2
    exit 1
  fi
fi
echo "[init.sh] Starting with ${COMPOSE_FILE} ..."

compose_cmd=()
if docker compose version >/dev/null 2>&1; then
  compose_cmd=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose_cmd=(docker-compose)
else
  echo "docker compose not found"
  exit 1
fi

if "${compose_cmd[@]}" -f "${COMPOSE_FILE}" config --services 2>/dev/null | grep -qx 'yts-dbt'; then
  echo "[init.sh] Building local yts-dbt image ..."
  "${compose_cmd[@]}" -f "${COMPOSE_FILE}" build yts-dbt
fi

"${compose_cmd[@]}" -f "${COMPOSE_FILE}" up -d

sleep 2
fix_pg_permissions

BASE_DOMAIN="$(grep '^BASE_DOMAIN=' .env | cut -d= -f2)"
for h in sso minio trino nessie airbyte dbt doris meta portal admin ai assist ranger; do
  echo "https://${h}.${BASE_DOMAIN}"
done
TRAEFIK_DASHBOARD_ENABLED="$(grep '^TRAEFIK_DASHBOARD=' .env | cut -d= -f2)"
if [[ "${TRAEFIK_DASHBOARD_ENABLED}" == "true" ]]; then
  HOST_TRAEFIK_URL="$(grep '^HOST_TRAEFIK=' .env | cut -d= -f2)"
  TRAEFIK_DASHBOARD_PORT_VALUE="$(grep '^TRAEFIK_DASHBOARD_PORT=' .env | cut -d= -f2)"
  echo "https://${HOST_TRAEFIK_URL} (Traefik dashboard)"
  echo "http://localhost:${TRAEFIK_DASHBOARD_PORT_VALUE} (local Traefik dashboard via --api.insecure)"
fi
