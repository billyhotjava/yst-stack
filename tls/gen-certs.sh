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
