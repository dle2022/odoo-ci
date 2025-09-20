#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?Usage: backup_docker.sh <prod|staging>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.${ENV}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 2; }

# load env
set -a; source "$ENV_FILE"; set +a

TS="$(date +%Y%m%d_%H%M%S)"
TMP="${ROOT}/.tmp-backup-${ENV}-${TS}"
mkdir -p "$TMP" "${BACKUP_ROOT}"

echo "==> Dumping DB from container: ${DB_CONT}"
docker exec -e PGPASSWORD="${PGPASSWORD}" "$DB_CONT" \
  pg_dump -U "${DB_USER}" -p "${DB_PORT}" -F c -d "${DB_NAME}" -f /tmp/db.dump
docker cp "${DB_CONT}:/tmp/db.dump" "${TMP}/db.dump"
docker exec "$DB_CONT" rm -f /tmp/db.dump || true

echo "==> Copying filestore from app container: ${APP_CONT}"
mkdir -p "${TMP}/filestore"
docker cp "${APP_CONT}:${FILESTORE_IN_APP}/." "${TMP}/filestore/" || true

# Optional config snapshot if you keep them in repo
mkdir -p "${TMP}/config"
[[ -f "${ROOT}/odoo/config/odoo.${ENV}.conf" ]] && cp -a "${ROOT}/odoo/config/odoo.${ENV}.conf" "${TMP}/config/" || true

OUT="${BACKUP_ROOT}/${ENV}_odoo_${DB_NAME}_${TS}.tar.gz"
tar -C "${TMP}" -czf "${OUT}" db.dump filestore config 2>/dev/null || tar -C "${TMP}" -czf "${OUT}" db.dump filestore
sha256sum "${OUT}" > "${OUT}.sha256"
rm -rf "${TMP}"

# prune old
find "${BACKUP_ROOT}" -type f -name "${ENV}_odoo_*.tar.gz" -mtime +${RETENTION_DAYS:-14} -delete || true

echo "BACKUP_PATH=${OUT}"
