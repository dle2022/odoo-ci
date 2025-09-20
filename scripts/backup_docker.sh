#!/usr/bin/env bash
set -euo pipefail

# Usage: backup_docker.sh prod|staging
ENV="${1:?Usage: backup_docker.sh <prod|staging>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.${ENV}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 2; }

# Load env (DB_NAME, POSTGRES_USER, POSTGRES_PASSWORD, APP_CONT, DB_CONT, FILESTORE_IN_APP, ...)
set -a; source "$ENV_FILE"; set +a

BACKUP_ROOT="${BACKUP_ROOT:-/srv/backups}"
DB_PORT="${DB_PORT:-5432}"
APP_CONT="${APP_CONT:-odoo-${ENV}-app}"
DB_CONT="${DB_CONT:-odoo-${ENV}-db}"
FILESTORE_IN_APP="${FILESTORE_IN_APP:-/var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME}}"

TS="$(date +%Y%m%d_%H%M%S)"
TMP="${ROOT}/.tmp-backup-${ENV}-${TS}"
OUT="${BACKUP_ROOT}/${ENV}_odoo_${DB_NAME}_${TS}.tar.gz"

mkdir -p "$TMP" "$BACKUP_ROOT"

echo "==> ENV.............: ${ENV}"
echo "==> APP_CONT........: ${APP_CONT}"
echo "==> DB_CONT.........: ${DB_CONT}"
echo "==> DB_NAME.........: ${DB_NAME}"
echo "==> FILESTORE_IN_APP: ${FILESTORE_IN_APP}"
echo "==> OUT.............: ${OUT}"

echo "==> Preflight: check filestore path in app container"
if docker exec "${APP_CONT}" bash -lc "test -d '${FILESTORE_IN_APP}'"; then
  docker exec "${APP_CONT}" bash -lc "du -sh '${FILESTORE_IN_APP}' || true"
else
  echo "WARN: Filestore path not found in container: ${FILESTORE_IN_APP}" >&2
fi

echo "==> Dumping DB from ${DB_CONT}"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  "${DB_CONT}" pg_dump -U "${POSTGRES_USER}" -p "${DB_PORT}" -F c -d "${DB_NAME}" -f /tmp/db.dump
docker cp "${DB_CONT}:/tmp/db.dump" "${TMP}/db.dump"
# After copying DB dump out of the DB container:
if [[ ! -s "${TMP}/db.dump" ]]; then
  echo "ERROR: db.dump is missing or empty after pg_dump + docker cp." >&2
  exit 3
fi
echo "==> DB dump size: $(du -h "${TMP}/db.dump" | awk '{print $1}')"

# After ensuring filestore dir exists and attempting docker cp:
COUNT=$(find "${TMP}/filestore" -type f | wc -l | tr -d ' ')
SIZE=$(du -sh "${TMP}/filestore" 2>/dev/null | awk '{print $1}')
echo "==> Filestore copied: files=${COUNT} size=${SIZE:-0}"

docker exec "${DB_CONT}" rm -f /tmp/db.dump || true

echo "==> Copying filestore from ${APP_CONT}:${FILESTORE_IN_APP}"
mkdir -p "${TMP}/filestore"
if ! docker cp "${APP_CONT}:${FILESTORE_IN_APP}/." "${TMP}/filestore/"; then
  echo "WARN: docker cp filestore failed (path may be empty or missing): ${FILESTORE_IN_APP}" >&2
fi

# OPTIONAL: include a known-good config snapshot from the repo (not from container)
mkdir -p "${TMP}/config"
if [[ -f "${ROOT}/odoo/config/odoo.${ENV}.conf" ]]; then
  cp -a "${ROOT}/odoo/config/odoo.${ENV}.conf" "${TMP}/config/"
fi

# Report what we actually copied
COUNT=$(find "${TMP}/filestore" -type f | wc -l | tr -d ' ')
SIZE=$(du -sh "${TMP}/filestore" 2>/dev/null | awk '{print $1}')
echo "==> Filestore copied: files=${COUNT} size=${SIZE:-0}"

echo "==> Creating archive ${OUT}"
tar -C "${TMP}" -czf "${OUT}" db.dump filestore config 2>/dev/null || tar -C "${TMP}" -czf "${OUT}" db.dump filestore
sha256sum "${OUT}" > "${OUT}.sha256"
rm -rf "${TMP}"

# Retention
RETENTION_DAYS="${RETENTION_DAYS:-14}"
find "${BACKUP_ROOT}" -type f -name "${ENV}_odoo_*.tar.gz" -mtime +${RETENTION_DAYS} -delete || true

echo "BACKUP_PATH=${OUT}"
