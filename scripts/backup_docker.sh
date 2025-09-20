#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/backup_docker.sh prod
#   ./scripts/backup_docker.sh staging

ENV="${1:?Usage: backup_docker.sh <prod|staging>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.${ENV}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 2; }

# Load env (allow indirect refs like ${POSTGRES_USER})
set -a; source "$ENV_FILE"; set +a

# Defaults / normalization
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/github-runner/backups}"
DB_PORT="${DB_PORT:-5432}"
APP_CONT="${APP_CONT:-odoo-${ENV}-app}"
DB_CONT="${DB_CONT:-odoo-${ENV}-db}"

# Normalize DB user/password (fall back sanely if env used ${POSTGRES_*})
DB_USER="${DB_USER:-${POSTGRES_USER:-}}"
PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"

# --- Guard: must have a valid DB_USER ---
if [[ -z "$DB_USER" ]]; then
  echo "ERROR: DB_USER/POSTGRES_USER not set; cannot run pg_dump." >&2
  exit 3
fi

# --- Resolve DB_NAME if missing ---
# 1) from POSTGRES_DB in DB container, 2) from filestore folder name
if [[ -z "${DB_NAME:-}" ]]; then
  set +e
  DB_NAME_FROM_ENV="$(docker exec "$DB_CONT" bash -lc 'printf "%s" "$POSTGRES_DB"' 2>/dev/null)"
  set -e
  if [[ -n "$DB_NAME_FROM_ENV" ]]; then
    DB_NAME="$DB_NAME_FROM_ENV"
  fi
fi

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

# --- Guard: DB_NAME must be set and must NOT be 'postgres' ---
if [[ -z "${DB_NAME:-}" || "$DB_NAME" == "postgres" ]]; then
  echo "ERROR: DB_NAME is empty or 'postgres'. Set DB_NAME in .env.prod to the actual Odoo DB name." >&2
  exit 3
fi

# --- Fix FILESTORE_IN_APP path (now that DB_NAME is known) ---
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

# --- Verify BACKUP_ROOT before writing ---
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


#mkdir -p "${TMP}" "${BACKUP_ROOT}"
#echo "==> ENV.............: ${ENV}"
#echo "==> APP_CONT........: ${APP_CONT}"
#echo "==> DB_CONT.........: ${DB_CONT}"
#echo "==> DB_NAME.........: ${DB_NAME}"
#echo "==> DB_USER.........: ${DB_USER}"
#echo "==> FILESTORE_IN_APP: ${FILESTORE_IN_APP}"
#echo "==> OUT.............: ${OUT}"

# ---- Preflight: verify containers & filestore path ----
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

# ===================== DB DUMP =====================
echo "==> Dumping DB from ${DB_CONT}"
DB_TMP_DIR="/var/lib/postgresql/tmp-backup"
docker exec "${DB_CONT}" bash -lc "rm -rf '${DB_TMP_DIR}'; mkdir -p '${DB_TMP_DIR}' && chmod 700 '${DB_TMP_DIR}'"

# Prefer custom format (-Fc) for reliable restores
if [[ -n "$PGPASSWORD" ]]; then
  docker exec -e PGPASSWORD="${PGPASSWORD}" \
    "${DB_CONT}" bash -lc "pg_dump -U '${DB_USER}' -d '${DB_NAME}' -F c -f '${DB_TMP_DIR}/db.dump'"
else
  docker exec \
    "${DB_CONT}" bash -lc "pg_dump -U '${DB_USER}' -d '${DB_NAME}' -F c -f '${DB_TMP_DIR}/db.dump'"
fi

docker cp "${DB_CONT}:${DB_TMP_DIR}/db.dump" "${TMP}/db.dump"
docker exec "${DB_CONT}" bash -lc "rm -rf '${DB_TMP_DIR}'"

if [[ ! -s "${TMP}/db.dump" ]]; then
  echo "ERROR: db.dump is missing or empty after pg_dump + docker cp." >&2
  ls -l "${TMP}" || true
  exit 5
fi
echo "==> DB dump size: $(du -h "${TMP}/db.dump" | awk '{print $1}')"

# ===================== FILESTORE COPY =====================
echo "==> Copying filestore"
mkdir -p "${TMP}/filestore"
# Use tar over STDOUT to avoid docker cp quirks & preserve perms
if docker exec "${APP_CONT}" bash -lc "test -d '${FILESTORE_IN_APP}'"; then
  docker exec "${APP_CONT}" bash -lc "tar -C '${FILESTORE_IN_APP%/}' -czf - '.'" > "${TMP}/filestore.tgz" || {
    echo "WARN: tar of filestore failed; continuing without filestore." >&2
    rm -f "${TMP}/filestore.tgz"
  }
else
  echo "WARN: Skipping filestore (path missing): ${FILESTORE_IN_APP}" >&2
fi

# ===================== PACKAGE BACKUP =====================
echo "==> Creating archive ${OUT}"
# Build a manifest for transparency
cat > "${TMP}/manifest.txt" <<EOF
env=${ENV}
timestamp=${TS}
db_name=${DB_NAME}
db_user=${DB_USER}
app_container=${APP_CONT}
db_container=${DB_CONT}
filestore=${FILESTORE_IN_APP}
EOF

# Compose final tar: db.dump + optional filestore.tgz + manifest
if [[ -f "${TMP}/filestore.tgz" ]]; then
  tar -C "${TMP}" -czf "${OUT}" db.dump filestore.tgz manifest.txt
else
  tar -C "${TMP}" -czf "${OUT}" db.dump manifest.txt
fi
sha256sum "${OUT}" > "${OUT}.sha256"

# cleanup
rm -rf "${TMP}"

# retention
RETENTION_DAYS="${RETENTION_DAYS:-14}"
find "${BACKUP_ROOT}" -type f -name "${ENV}_odoo_*.tar.gz" -mtime +${RETENTION_DAYS} -delete || true
find "${BACKUP_ROOT}" -type f -name "${ENV}_odoo_*.tar.gz.sha256" -mtime +${RETENTION_DAYS} -delete || true

echo "BACKUP_PATH=${OUT}"
echo "==> Done."
