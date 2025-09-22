#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}"
BASE_DOMAIN="${BASE_DOMAIN:-yst.local}"
mkdir -p "${CERT_DIR}"
if [[ -f "${CERT_DIR}/server.crt" && -f "${CERT_DIR}/server.key" ]]; then
  if openssl x509 -in "${CERT_DIR}/server.crt" -noout -ext subjectAltName 2>/dev/null | \
    grep -F "DNS:*.${BASE_DOMAIN}" >/dev/null; then
    echo "[certs] TLS certificates already exist, skip generation."
    exit 0
  fi
  echo "[certs] Existing certificate SAN does not match *.${BASE_DOMAIN}, regenerating ..."
fi
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "${CERT_DIR}/server.key" \
  -out "${CERT_DIR}/server.crt" \
  -subj "/CN=*.${BASE_DOMAIN}/O=YTS" \
  -addext "subjectAltName=DNS:*.${BASE_DOMAIN},DNS:${BASE_DOMAIN}"
echo "[certs] generated ${CERT_DIR}/server.crt & server.key"
