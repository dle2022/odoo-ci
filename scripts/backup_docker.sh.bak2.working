#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?Usage: backup_docker.sh <prod|staging>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.${ENV}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 2; }

set -a; source "$ENV_FILE"; set +a

BACKUP_ROOT="${BACKUP_ROOT:-/srv/backups}"
DB_PORT="${DB_PORT:-5432}"
APP_CONT="${APP_CONT:-odoo-${ENV}-app}"
DB_CONT="${DB_CONT:-odoo-${ENV}-db}"
FILESTORE_IN_APP="${FILESTORE_IN_APP:-/var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME}}"

TS="$(date +%Y%m%d_%H%M%S)"
TMP="${ROOT}/.tmp-backup-${ENV}-${TS}"
OUT="${BACKUP_ROOT}/${ENV}_odoo_${DB_NAME}_${TS}.tar.gz"

echo "PWD=$(pwd)"
echo "ROOT=${ROOT}"
echo "TMP=${TMP}"
mkdir -p "${TMP}" "${BACKUP_ROOT}"
ls -ld "${TMP}" || true

echo "==> ENV.............: ${ENV}"
echo "==> APP_CONT........: ${APP_CONT}"
echo "==> DB_CONT.........: ${DB_CONT}"
echo "==> DB_NAME.........: ${DB_NAME}"
echo "==> FILESTORE_IN_APP: ${FILESTORE_IN_APP}"
echo "==> OUT.............: ${OUT}"

echo "==> Preflight: filestore path in container"
if docker exec "${APP_CONT}" bash -lc "test -d '${FILESTORE_IN_APP}'"; then
  docker exec "${APP_CONT}" bash -lc "du -sh '${FILESTORE_IN_APP}' || true"
else
  echo "WARN: Filestore path not found in container: ${FILESTORE_IN_APP}" >&2
fi


# --- inside scripts/backup_docker.sh, replace the DB dump block with this ---

echo "==> Dumping DB from ${DB_CONT}"
DB_TMP_DIR="/var/lib/postgresql/tmp-backup"
# create a safe temp dir owned by the container's default user
docker exec "${DB_CONT}" bash -lc "rm -rf '${DB_TMP_DIR}'; mkdir -p '${DB_TMP_DIR}' && chmod 700 '${DB_TMP_DIR}'"

# do the dump into that dir
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  "${DB_CONT}" bash -lc "pg_dump -U '${POSTGRES_USER}' -d '${DB_NAME}' -F c -f '${DB_TMP_DIR}/db.dump'"

# copy out and clean up
docker cp "${DB_CONT}:${DB_TMP_DIR}/db.dump" "${TMP}/db.dump"
docker exec "${DB_CONT}" bash -lc "rm -rf '${DB_TMP_DIR}'"

# verify
if [[ ! -s "${TMP}/db.dump" ]]; then
  echo "ERROR: db.dump is missing or empty after pg_dump + docker cp." >&2
  ls -l "${TMP}" || true
  exit 3
fi
echo "==> DB dump size: $(du -h "${TMP}/db.dump" | awk '{print $1}')"



echo "==> Preparing filestore target dir"
mkdir -p "${TMP}/filestore"
ls -ld "${TMP}/filestore" || true

echo "==> Copying filestore from ${APP_CONT}:${FILESTORE_IN_APP}"
if ! docker cp "${APP_CONT}:${FILESTORE_IN_APP}/." "${TMP}/filestore/"; then
  echo "WARN: docker cp filestore failed (path may be empty or missing): ${FILESTORE_IN_APP}" >&2
fi

# show the directory state after copy attempt
ls -ld "${TMP}" "${TMP}/filestore" || true

COUNT=0
if [[ -d "${TMP}/filestore" ]]; then
  COUNT=$(find "${TMP}/filestore" -type f | wc -l | tr -d ' ')
fi
SIZE=$(du -sh "${TMP}/filestore" 2>/dev/null | awk '{print $1}')
echo "==> Filestore copied: files=${COUNT} size=${SIZE:-0}"

echo "==> Creating archive ${OUT}"
tar -C "${TMP}" -czf "${OUT}" db.dump filestore 2>/dev/null || tar -C "${TMP}" -czf "${OUT}" db.dump
sha256sum "${OUT}" > "${OUT}.sha256"

rm -rf "${TMP}"

RETENTION_DAYS="${RETENTION_DAYS:-14}"
find "${BACKUP_ROOT}" -type f -name "${ENV}_odoo_*.tar.gz" -mtime +${RETENTION_DAYS} -delete || true

echo "BACKUP_PATH=${OUT}"
