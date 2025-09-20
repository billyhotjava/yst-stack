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
