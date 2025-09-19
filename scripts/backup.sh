#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-staging}"   # staging | prod

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.${ENV}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 2; }
set -a; source "$ENV_FILE"; set +a

HOST="$(hostname -s)"
TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p "${BACKUP_ROOT}"

TMP="${ROOT}/.tmp-backup"
rm -rf "$TMP"; mkdir -p "$TMP"

export PGPASSWORD="${PGPASSWORD:-}"

# --- DB dump ---
if [[ -n "${PG_DOCKER_SERVICE:-}" ]]; then
  # e.g. set PG_DOCKER_SERVICE=db in .env if you want docker exec
  docker exec "${PG_DOCKER_SERVICE}" pg_dump -h localhost -p "${PGPORT:-5432}" -U "${PGUSER}" -F c -d "${PGDATABASE}" -f /tmp/db.dump
  docker cp "${PG_DOCKER_SERVICE}:/tmp/db.dump" "${TMP}/db.dump"
  docker exec "${PG_DOCKER_SERVICE}" rm -f /tmp/db.dump
else
  pg_dump -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -F c -d "${PGDATABASE}" -f "${TMP}/db.dump"
fi

# --- Filestore ---
SRC_FS="${FILESTORE_DIR:-/var/lib/odoo/.local/share/Odoo/filestore/${ODOO_DB}}"
mkdir -p "${TMP}/filestore"
rsync -a "${SRC_FS}/" "${TMP}/filestore/"

# --- Config (optional but handy) ---
mkdir -p "${TMP}/config"
CONF_GLOB="${ROOT}/odoo/config/odoo.${ENV}.conf"
[[ -f "${CONF_GLOB}" ]] && cp -a "${CONF_GLOB}" "${TMP}/config/" || true

# --- Make tarball ---
OUT="${BACKUP_ROOT}/${ENV}_${HOST}_${ODOO_DB}_${TS}.tar.gz"
tar -C "${TMP}" -czf "${OUT}" db.dump filestore config 2>/dev/null || \
tar -C "${TMP}" -czf "${OUT}" db.dump filestore
sha256sum "${OUT}" > "${OUT}.sha256"

# Cleanup temp + retention
rm -rf "${TMP}"
find "${BACKUP_ROOT}" -type f -name "${ENV}_*.tar.gz" -mtime +${RETENTION_DAYS:-14} -delete

echo "BACKUP_PATH=${OUT}"  # for CI to capture
