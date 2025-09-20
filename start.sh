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
    echo "[start.sh] WARNING: setfacl not found, falling back to chmod 777 on Postgres data directory." >&2
    chmod -R 777 "${pg_dir}" 2>/dev/null || true
  fi

  chown -R "${pg_runtime_uid}:${pg_runtime_gid}" "${pg_dir}" 2>/dev/null || true
}

prepare_data_dirs(){
  fix_pg_permissions

  local -a data_dirs=(
    "services/yts-proxy/data/certs"
    "services/yts-minio/data"
    "services/yts-minio-init/data"
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
  chmod -R 777 services/yts-om-es/data || true
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
    echo "[start.sh] detected partial Elasticsearch TLS assets under ${cert_dir}; provide the remaining files or remove them before rerunning." >&2
    return
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "[start.sh] ERROR: openssl not found; place TLS assets under ${cert_dir} or install openssl." >&2
    exit 1
  fi

  echo "[start.sh] generating self-signed Elasticsearch TLS assets under ${cert_dir}" >&2

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
  : "${KC_VERSION:=26.1}"
  : "${KC_ADMIN:=admin}"
  : "${KC_ADMIN_PWD:=${SECRET}}"
  : "${KC_REALM:=yts}"
  : "${KC_PROXY:=edge}"
  : "${KC_HOSTNAME:=sso.yts.local}"
  : "${KC_HOSTNAME_STRICT:=false}"
  : "${KC_HOSTNAME_STRICT_HTTPS:=false}"
  : "${KC_HTTP_ENABLED:=true}"
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
  : "${PG_DB_TEMPORAL_VISIBILITY:=yts_temporal_visibility}"

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
KC_PROXY=${KC_PROXY}
KC_HOSTNAME=${KC_HOSTNAME}
KC_HOSTNAME_STRICT=${KC_HOSTNAME_STRICT}
KC_HOSTNAME_STRICT_HTTPS=${KC_HOSTNAME_STRICT_HTTPS}
KC_HTTP_ENABLED=${KC_HTTP_ENABLED}
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
PG_DB_TEMPORAL_VISIBILITY=${PG_DB_TEMPORAL_VISIBILITY}
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
EOF
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
ensure_elasticsearch_tls_assets
if [[ "${MODE}" != "single" && "${ELASTICSEARCH_SECURITY_ENABLED}" != "true" ]]; then
  echo "[start.sh] ERROR: Production modes require ELASTICSEARCH_SECURITY_ENABLED=true." >&2
  exit 1
fi
if [[ "${ELASTICSEARCH_HTTP_SSL_ENABLED}" == "true" ]]; then
  missing_cert=0
  for cert_file in http.key http.crt ca.crt; do
    if [[ ! -f "${ELASTICSEARCH_CERTS_DIR}/${cert_file}" ]]; then
      echo "[start.sh] ERROR: Missing ${ELASTICSEARCH_CERTS_DIR}/${cert_file} required when Elasticsearch TLS is enabled." >&2
      missing_cert=1
    fi
  done
  if (( missing_cert )); then
    exit 1
  fi
fi
if [[ "${MODE}" == "single" ]]; then
  BASE_DOMAIN="${BASE_DOMAIN}" bash services/yts-proxy/init/gen-certs.sh || true
else
  if [[ ! -f services/yts-proxy/data/certs/server.crt || ! -f services/yts-proxy/data/certs/server.key ]]; then
    echo "[start.sh] ERROR: Production mode requires a CA-issued TLS certificate at services/yts-proxy/data/certs/server.crt and services/yts-proxy/data/certs/server.key." >&2
    exit 1
  fi
fi
echo "[start.sh] Starting with ${COMPOSE_FILE} ..."
if docker compose version >/dev/null 2>&1; then docker compose -f "${COMPOSE_FILE}" up -d
elif command -v docker-compose >/dev/null 2>&1; then docker-compose -f "${COMPOSE_FILE}" up -d
else echo "docker compose not found"; exit 1; fi

sleep 2
fix_pg_permissions

BASE_DOMAIN="$(grep '^BASE_DOMAIN=' .env | cut -d= -f2)"
for h in sso minio trino airbyte meta portal admin ai assist; do echo "https://${h}.${BASE_DOMAIN}"; done
TRAEFIK_DASHBOARD_ENABLED="$(grep '^TRAEFIK_DASHBOARD=' .env | cut -d= -f2)"
if [[ "${TRAEFIK_DASHBOARD_ENABLED}" == "true" ]]; then
  HOST_TRAEFIK_URL="$(grep '^HOST_TRAEFIK=' .env | cut -d= -f2)"
  TRAEFIK_DASHBOARD_PORT_VALUE="$(grep '^TRAEFIK_DASHBOARD_PORT=' .env | cut -d= -f2)"
  echo "https://${HOST_TRAEFIK_URL} (Traefik dashboard)"
  echo "http://localhost:${TRAEFIK_DASHBOARD_PORT_VALUE} (local Traefik dashboard via --api.insecure)"
fi
