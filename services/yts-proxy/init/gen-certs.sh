#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR%/init}/data/certs"
BASE_DOMAIN="${BASE_DOMAIN:-yts.local}"
mkdir -p "${CERT_DIR}"
if [[ -f "${CERT_DIR}/server.crt" && -f "${CERT_DIR}/server.key" ]]; then
  echo "[yts-proxy] TLS certificates already exist, skip generation."
  exit 0
fi
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "${CERT_DIR}/server.key" \
  -out "${CERT_DIR}/server.crt" \
  -subj "/CN=*.${BASE_DOMAIN}/O=YTS" \
  -addext "subjectAltName=DNS:*.${BASE_DOMAIN},DNS:${BASE_DOMAIN}"
echo "[yts-proxy] generated ${CERT_DIR}/server.crt & server.key"
