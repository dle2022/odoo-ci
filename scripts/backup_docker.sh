#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/backup_docker.sh prod|staging
ENV="${1:?Usage: backup_docker.sh <prod|staging>}"

# Resolve repo root and env file
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.${ENV}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 2; }

# Load .env.<env> into this shell (POSTGRES_* etc. become available)
set -a
source "$ENV_FILE"
set +a

# Defaults / fallbacks
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backups}"
DB_PORT="${DB_PORT:-5432}"

# If APP_CONT / DB_CONT weren't in your .env, derive them from ENV
APP_CONT="${APP_CONT:-odoo-${ENV}-app}"
DB_CONT="${DB_CONT:-odoo-${ENV}-db}"

# Path to filestore inside the app container (works with official odoo image)
FILESTORE_IN_APP="${FILESTORE_IN_APP:-/var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME}}"

# Scratch + output path
TS="$(date +%Y%m%d_%H%M%S)"
TMP="${ROOT}/.tmp-backup-${ENV}-${TS}"
OUT="${BACKUP_ROOT}/${ENV}_odoo_${DB_NAME}_${TS}.tar.gz"

mkdir -p "$TMP" "$BACKUP_ROOT"

echo "==> Dumping DB from ${DB_CONT} (db=${DB_NAME}, user=${POSTGRES_USER})"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  "${DB_CONT}" pg_dump -U "${POSTGRES_USER}" -p "${DB_PORT}" -F c -d "${DB_NAME}" -f /tmp/db.dump

docker cp "${DB_CONT}:/tmp/db.dump" "${TMP}/db.dump" && \
  docker exec "${DB_CONT}" rm -f /tmp/db.dump || true

# After copying filestore
COUNT=$(find "${TMP}/filestore" -type f | wc -l | tr -d ' ')
SIZE=$(du -sh "${TMP}/filestore" 2>/dev/null | awk "{print \$1}")
echo "==> Filestore files copied: ${COUNT} (size: ${SIZE:-0})"
if [ "$COUNT" = "0" ]; then
  echo "NOTE: Filestore appears empty. This is normal if your DB has no attachments yet."
fi


echo "==> Copying filestore from ${APP_CONT}:${FILESTORE_IN_APP}"
mkdir -p "${TMP}/filestore"
# copy may be empty on a brand-new DB; that's ok
docker cp "${APP_CONT}:${FILESTORE_IN_APP}/." "${TMP}/filestore/" 2>/dev/null || true

# (optional) include config snapshot if you keep per-env conf in repo
mkdir -p "${TMP}/config"
[[ -f "${ROOT}/odoo/config/odoo.${ENV}.conf" ]] && \
  cp -a "${ROOT}/odoo/config/odoo.${ENV}.conf" "${TMP}/config/" || true

echo "==> Creating ${OUT}"
tar -C "${TMP}" -czf "${OUT}" db.dump filestore config 2>/dev/null \
  || tar -C "${TMP}" -czf "${OUT}" db.dump filestore
sha256sum "${OUT}" > "${OUT}.sha256"

rm -rf "${TMP}"

# keep last N days (default 14)
RETENTION_DAYS="${RETENTION_DAYS:-14}"
find "${BACKUP_ROOT}" -type f -name "${ENV}_odoo_*.tar.gz" -mtime +${RETENTION_DAYS} -delete || true

echo "BACKUP_PATH=${OUT}"
