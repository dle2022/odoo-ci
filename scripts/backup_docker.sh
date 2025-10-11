#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/backup_docker.sh prod
#   ./scripts/backup_docker.sh staging

ENV="${1:?Usage: backup_docker.sh <prod|staging>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Prefer split backup env (.env.backup.<env>) if present, otherwise fall back to .env.<env>
BACKUP_ENV_CANDIDATE="${ROOT}/.env.backup.${ENV}"
DEPLOY_ENV_CANDIDATE="${ROOT}/.env.${ENV}"
if [[ -f "$BACKUP_ENV_CANDIDATE" ]]; then
  ENV_FILE="$BACKUP_ENV_CANDIDATE"
elif [[ -f "$DEPLOY_ENV_CANDIDATE" ]]; then
  ENV_FILE="$DEPLOY_ENV_CANDIDATE"
else
  echo "ERROR: Missing env file. Looked for:"
  echo "  $BACKUP_ENV_CANDIDATE"
  echo "  $DEPLOY_ENV_CANDIDATE"
  exit 2
fi

# --- Source env with CRLF protection (strip trailing \r) ---
set -a
# shellcheck disable=SC1090
source <(sed -e 's/\r$//' "$ENV_FILE")
set +a

echo "DBG: using ENV_FILE=$ENV_FILE"
echo "DBG: POSTGRES_USER='${POSTGRES_USER:-<unset>}' DB_USER(before)='${DB_USER:-<unset>}' DB_NAME='${DB_NAME:-<unset>}'"

# ---------- Normalization / defaults ----------
# IMPORTANT: default to $HOME/backups (runner's home)
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"
DB_PORT="${DB_PORT:-5432}"
APP_CONT="${APP_CONT:-odoo-${ENV}-app}"
DB_CONT="${DB_CONT:-odoo-${ENV}-db}"

# DB role/password: prefer explicit DB_USER/PGPASSWORD; else POSTGRES_*; else 'odoo'
DB_USER="${DB_USER:-${POSTGRES_USER:-odoo}}"
PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"

# Guard: must have some DB user (we default to 'odoo' above)
if [[ -z "$DB_USER" ]]; then
  echo "ERROR: DB_USER/POSTGRES_USER not set; cannot run pg_dump." >&2
  exit 3
fi

# ---------- Resolve DB_NAME if missing ----------
# 1) try POSTGRES_DB in the DB container
if [[ -z "${DB_NAME:-}" ]]; then
  set +e
  DB_NAME_FROM_ENV="$(docker exec "$DB_CONT" bash -lc 'printf "%s" "$POSTGRES_DB"' 2>/dev/null)"
  set -e
  if [[ -n "$DB_NAME_FROM_ENV" ]]; then
    DB_NAME="$DB_NAME_FROM_ENV"
  fi
fi
# 2) try inferring from filestore
if [[ -z "${DB_NAME:-}" ]]; then
  FILESTORE_BASE_DEFAULT="/var/lib/odoo/.local/share/Odoo/filestore"
  FS_ROOT_CANDIDATE="${FILESTORE_IN_APP:-${FILESTORE_BASE_DEFAULT}/}"
  FS_BASE="${FS_ROOT_CANDIDATE%/}"
  set +e
  GUESSED_DB="$(docker exec "$APP_CONT" bash -lc "ls -1d ${FS_BASE}/* 2>/dev/null | head -1 | xargs -r basename" 2>/dev/null)"
  set -e
  if [[ -n "$GUESSED_DB" ]]; then
    DB_NAME="$GUESSED_DB"
  fi
fi

# Guard: DB_NAME must be set and must NOT be 'postgres'
if [[ -z "${DB_NAME:-}" || "$DB_NAME" == "postgres" ]]; then
  echo "ERROR: DB_NAME is empty or 'postgres'. Set DB_NAME in your env file to the actual Odoo DB name." >&2
  exit 3
fi

# ---------- Build a correct FILESTORE_IN_APP once DB_NAME is known ----------
if [[ -z "${FILESTORE_IN_APP:-}" ]]; then
  FILESTORE_IN_APP="/var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME}"
else
  case "$FILESTORE_IN_APP" in
    */filestore)   FILESTORE_IN_APP="${FILESTORE_IN_APP}/${DB_NAME}" ;;
    */filestore/)  FILESTORE_IN_APP="${FILESTORE_IN_APP}${DB_NAME}" ;;
    */)            FILESTORE_IN_APP="${FILESTORE_IN_APP}${DB_NAME}" ;;
  esac
fi

TS="$(date +%Y%m%d_%H%M%S)"
TMP="${ROOT}/.tmp-backup-${ENV}-${TS}"
OUT="${BACKUP_ROOT}/${ENV}_odoo_${DB_NAME}_${TS}.tar.gz"

# ---------- Verify BACKUP_ROOT before writing ----------
mkdir -p "$BACKUP_ROOT" || true
if [[ ! -w "$BACKUP_ROOT" ]]; then
  echo "ERROR: BACKUP_ROOT not writable: $BACKUP_ROOT (user=$(id -u -n))" >&2
  ls -ld "$BACKUP_ROOT" >&2 || true
  exit 10
fi

mkdir -p "${TMP}"

echo "==> ENV.............: ${ENV}"
echo "==> APP_CONT........: ${APP_CONT}"
echo "==> DB_CONT.........: ${DB_CONT}"
echo "==> DB_NAME.........: ${DB_NAME}"
echo "==> DB_USER.........: ${DB_USER}"
echo "==> FILESTORE_IN_APP: ${FILESTORE_IN_APP}"
echo "==> OUT.............: ${OUT}"

# ---------- Preflight ----------
set +e
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E "(${APP_CONT}|${DB_CONT})" >/dev/null
[[ $? -eq 0 ]] || { echo "ERROR: One or both containers not running: ${APP_CONT}, ${DB_CONT}"; exit 4; }
set -e

echo "==> Checking filestore path in ${APP_CONT}"
if docker exec "${APP_CONT}" bash -lc "test -d '${FILESTORE_IN_APP}'"; then
  docker exec "${APP_CONT}" bash -lc "du -sh '${FILESTORE_IN_APP}' || true"
else
  echo "WARN: Filestore path not found in container: ${FILESTORE_IN_APP}" >&2
fi

# ---------- DB BACKUP (PLAIN SQL, GZIPPED) ----------
echo "==> Dumping DB (plain SQL, gzipped) from ${DB_CONT}"
DB_TMP_DIR="/var/lib/postgresql/tmp-backup"
docker exec "${DB_CONT}" bash -lc "rm -rf '${DB_TMP_DIR}'; mkdir -p '${DB_TMP_DIR}' && chmod 700 '${DB_TMP_DIR}'"

# Create /tmp/db.sql.gz inside DB container, then copy it out
if [[ -n "$PGPASSWORD" ]]; then
  docker exec -e PGPASSWORD="${PGPASSWORD}" \
    "${DB_CONT}" bash -lc "pg_dump -Fp -U '${DB_USER}' -d '${DB_NAME}' | gzip -c > '${DB_TMP_DIR}/db.sql.gz'"
else
  docker exec \
    "${DB_CONT}" bash -lc "pg_dump -Fp -U '${DB_USER}' -d '${DB_NAME}' | gzip -c > '${DB_TMP_DIR}/db.sql.gz'"
fi

docker cp "${DB_CONT}:${DB_TMP_DIR}/db.sql.gz" "${TMP}/db.sql.gz"
docker exec "${DB_CONT}" bash -lc "rm -rf '${DB_TMP_DIR}'"

if [[ ! -s "${TMP}/db.sql.gz" ]]; then
  echo "ERROR: db.sql.gz is missing or empty after pg_dump + docker cp." >&2
  ls -l "${TMP}" || true
  exit 5
fi
echo "==> DB SQL size: $(du -h "${TMP}/db.sql.gz" | awk '{print $1}')"

# ---------- FILESTORE ----------
echo "==> Copying filestore"
# Use tar over STDOUT to avoid docker cp quirks & preserve perms
if docker exec "${APP_CONT}" bash -lc "test -d '${FILESTORE_IN_APP}'"; then
  if ! docker exec "${APP_CONT}" bash -lc "tar -C '${FILESTORE_IN_APP%/}' -czf - '.'" > "${TMP}/filestore.tgz"; then
    echo "WARN: tar of filestore failed; continuing without filestore." >&2
    rm -f "${TMP}/filestore.tgz"
  fi
else
  echo "WARN: Skipping filestore (path missing): ${FILESTORE_IN_APP}" >&2
fi

# ---------- PACKAGE BACKUP ----------
echo "==> Creating archive ${OUT}"
cat > "${TMP}/manifest.txt" <<EOF
env=${ENV}
timestamp=${TS}
db_name=${DB_NAME}
db_user=${DB_USER}
app_container=${APP_CONT}
db_container=${DB_CONT}
filestore=${FILESTORE_IN_APP}
EOF

# NOTE: package db.sql.gz (not db.dump)
if [[ -f "${TMP}/filestore.tgz" ]]; then
  tar -C "${TMP}" -czf "${OUT}" db.sql.gz filestore.tgz manifest.txt
else
  tar -C "${TMP}" -czf "${OUT}" db.sql.gz manifest.txt
fi
sha256sum "${OUT}" > "${OUT}.sha256"

# ---------- Cleanup & retention ----------
rm -rf "${TMP}"

RETENTION_DAYS="${RETENTION_DAYS:-14}"
find "${BACKUP_ROOT}" -type f -name "${ENV}_odoo_*.tar.gz"        -mtime +${RETENTION_DAYS} -delete || true
find "${BACKUP_ROOT}" -type f -name "${ENV}_odoo_*.tar.gz.sha256" -mtime +${RETENTION_DAYS} -delete || true

echo "BACKUP_PATH=${OUT}"
echo "==> Done."
