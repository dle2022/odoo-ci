#!/usr/bin/env bash
# Clone Production Odoo to Staging using an existing prod backup tarball.
# Works with backups created by scripts/backup_docker.sh (db.dump + filestore.tgz).
#
# Usage:
#   ./scripts/clone_prod_to_staging.sh [--from /path/to/prod_backup.tar.gz] [--from-latest] \
#       [--prod-env .env.backup.prod|.env.prod] [--stage-env .env.backup.staging|.env.staging]
#
# If neither --from nor --from-latest is given, the script defaults to --from-latest.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

#------------- args -------------
BACKUP_PATH=""
PROD_ENV_FILE=""
STAGE_ENV_FILE=""
USE_LATEST=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      BACKUP_PATH="${2:?--from requires a path}"
      USE_LATEST=false
      shift 2
      ;;
    --from-latest)
      USE_LATEST=true
      shift
      ;;
    --prod-env)
      PROD_ENV_FILE="${2:?--prod-env requires a file path}"
      shift 2
      ;;
    --stage-env)
      STAGE_ENV_FILE="${2:?--stage-env requires a file path}"
      shift 2
      ;;
    -h|--help)
      sed -n '1,60p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2; exit 1
      ;;
  esac
done

#------------- env detection (mirror backup_docker.sh behavior) -------------
# Prefer split backup envs if present; otherwise fall back to non-split .env files.
PROD_ENV_FILE="${PROD_ENV_FILE:-$([[ -f "${PROJECT_DIR}/.env.backup.prod" ]] && echo "${PROJECT_DIR}/.env.backup.prod" || echo "${PROJECT_DIR}/.env.prod")}"
STAGE_ENV_FILE="${STAGE_ENV_FILE:-$([[ -f "${PROJECT_DIR}/.env.backup.staging" ]] && echo "${PROJECT_DIR}/.env.backup.staging" || echo "${PROJECT_DIR}/.env.staging")}"

[[ -f "$PROD_ENV_FILE" ]]  || { echo "Missing $PROD_ENV_FILE"; exit 2; }
[[ -f "$STAGE_ENV_FILE" ]] || { echo "Missing $STAGE_ENV_FILE"; exit 2; }

# Load PROD env (for BACKUP_ROOT and prod DB name)
set -a; source "$PROD_ENV_FILE"; set +a
BACKUP_ROOT="${BACKUP_ROOT:-/home/github-runner/backups}"
DB_USER_PROD="${DB_USER:-${POSTGRES_USER:-odoo}}"
PGPASSWORD_PROD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"
DB_NAME_PROD="${DB_NAME:-}"
# We may not strictly need PROD creds since we restore from tarball, but we read prod DB name
# to pattern-match the latest backup file if needed.

# Load STAGING env (for target containers/paths/creds)
set -a; source "$STAGE_ENV_FILE"; set +a
DB_USER_STAGE="${DB_USER:-${POSTGRES_USER:-odoo}}"
PGPASSWORD_STAGE="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"
DB_NAME_STAGE="${DB_NAME:?DB_NAME missing in $STAGE_ENV_FILE}"
FILESTORE_IN_APP_STAGE="${FILESTORE_IN_APP:-/var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME_STAGE}}"

#------------- choose backup tarball -------------
if $USE_LATEST && [[ -z "$BACKUP_PATH" ]]; then
  # Find the latest prod backup tar produced by backup_docker.sh
  # Pattern: ${ENV}_odoo_${DB_NAME}_${YYYYMMDD_HHMMSS}.tar.gz  (ENV is 'prod' for production)
  if [[ -z "${DB_NAME_PROD}" ]]; then
    # Fall back: glob any prod tar.gz and sort by mtime
    CANDIDATE=$(ls -1t "${BACKUP_ROOT}/prod_odoo_"*.tar.gz 2>/dev/null | head -1 || true)
  else
    CANDIDATE=$(ls -1t "${BACKUP_ROOT}/prod_odoo_${DB_NAME_PROD}_"*.tar.gz 2>/dev/null | head -1 || true)
  fi
  [[ -n "$CANDIDATE" ]] || { echo "No prod backups found in ${BACKUP_ROOT}"; exit 3; }
  BACKUP_PATH="$CANDIDATE"
fi

[[ -f "$BACKUP_PATH" ]] || { echo "Backup tar not found: $BACKUP_PATH"; exit 4; }

echo "==> Using backup: $BACKUP_PATH"

# Optional checksum verification
if [[ -f "${BACKUP_PATH}.sha256" ]]; then
  echo "==> Verifying checksum ..."
  # Busybox 'sha256sum -c' expects 'filename' not path; handle correctly:
  # Create a temp copy with matching name to avoid false-negative
  TMP_DIR_CHECK="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR_CHECK" || true' EXIT
  cp "$BACKUP_PATH" "$TMP_DIR_CHECK/"
  BASENAME_BACKUP="$(basename "$BACKUP_PATH")"
  # Create a temp .sha256 file with corrected filename
  awk -v f="$BASENAME_BACKUP" '{print $1"  "f}' "${BACKUP_PATH}.sha256" > "${TMP_DIR_CHECK}/${BASENAME_BACKUP}.sha256"
  (cd "$TMP_DIR_CHECK" && sha256sum -c "${BASENAME_BACKUP}.sha256")
  rm -rf "$TMP_DIR_CHECK"
fi

#------------- locate compose files & containers -------------
PROD_COMPOSE="${PROJECT_DIR}/compose/prod/docker-compose.yml"
STAGE_COMPOSE="${PROJECT_DIR}/compose/staging/docker-compose.yml"

# We only need staging containers for restore (db + odoo)
SDB="$(docker compose -f "${STAGE_COMPOSE}" ps -q db || true)"
SOD="$(docker compose -f "${STAGE_COMPOSE}" ps -q odoo || true)"
[[ -n "$SDB" && -n "$SOD" ]] || {
  echo "ERROR: Staging containers not found. Ensure compose/staging/docker-compose.yml is up and 'db' and 'odoo' services are running." >&2
  exit 5
}

#------------- unpack backup tar -------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" || true' EXIT

echo "==> Extracting backup into temp dir ..."
tar -C "$WORK_DIR" -xzf "$BACKUP_PATH"

# The backup format (from backup_docker.sh):
#   db.dump            - pg_dump custom format (-Fc)
#   filestore.tgz      - tar.gz of filestore (optional)
#   manifest.txt       - info (env, timestamp, db_name, etc.)
[[ -f "${WORK_DIR}/db.dump" ]] || { echo "db.dump missing inside backup."; exit 6; }

# Read manifest (optional)
if [[ -f "${WORK_DIR}/manifest.txt" ]]; then
  echo "==> Manifest:"
  cat "${WORK_DIR}/manifest.txt" || true
fi

#------------- stop staging app to freeze writes -------------
echo "==> Stopping staging app container ..."
docker stop "$SOD" >/dev/null

#------------- restore database (pg_restore from -Fc) -------------
echo "==> Recreating STAGING database '${DB_NAME_STAGE}' ..."
if [[ -n "$PGPASSWORD_STAGE" ]]; then
  docker exec -e PGPASSWORD="${PGPASSWORD_STAGE}" -i "${SDB}" \
    psql -U "${DB_USER_STAGE}" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME_STAGE}';" || true
  docker exec -e PGPASSWORD="${PGPASSWORD_STAGE}" -i "${SDB}" \
    psql -U "${DB_USER_STAGE}" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${DB_NAME_STAGE}\";"
  docker exec -e PGPASSWORD="${PGPASSWORD_STAGE}" -i "${SDB}" \
    psql -U "${DB_USER_STAGE}" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"${DB_NAME_STAGE}\" OWNER \"${DB_USER_STAGE}\";"
  # copy & restore
  docker cp "${WORK_DIR}/db.dump" "${SDB}:/tmp/db.dump"
  docker exec -e PGPASSWORD="${PGPASSWORD_STAGE}" -i "${SDB}" \
    pg_restore -U "${DB_USER_STAGE}" -d "${DB_NAME_STAGE}" -c -O -x /tmp/db.dump
  docker exec "${SDB}" bash -lc "rm -f /tmp/db.dump"
else
  docker exec -i "${SDB}" \
    psql -U "${DB_USER_STAGE}" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME_STAGE}';" || true
  docker exec -i "${SDB}" \
    psql -U "${DB_USER_STAGE}" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${DB_NAME_STAGE}\";"
  docker exec -i "${SDB}" \
    psql -U "${DB_USER_STAGE}" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"${DB_NAME_STAGE}\" OWNER \"${DB_USER_STAGE}\";"
  docker cp "${WORK_DIR}/db.dump" "${SDB}:/tmp/db.dump"
  docker exec -i "${SDB}" \
    pg_restore -U "${DB_USER_STAGE}" -d "${DB_NAME_STAGE}" -c -O -x /tmp/db.dump
  docker exec "${SDB}" bash -lc "rm -f /tmp/db.dump"
fi

#------------- restore filestore (if present) -------------
if [[ -f "${WORK_DIR}/filestore.tgz" ]]; then
  echo "==> Restoring filestore into ${FILESTORE_IN_APP_STAGE}"
  docker cp "${WORK_DIR}/filestore.tgz" "${SOD}:/tmp/filestore.tgz"
  docker exec "${SOD}" bash -lc "mkdir -p '${FILESTORE_IN_APP_STAGE}' && rm -rf '${FILESTORE_IN_APP_STAGE}'/* || true"
  docker exec "${SOD}" bash -lc "tar -xzf /tmp/filestore.tgz -C '${FILESTORE_IN_APP_STAGE}' && rm -f /tmp/filestore.tgz"
else
  echo "WARN: filestore.tgz not found in backup; continuing with DB-only restore." >&2
fi

#------------- sanitize staging (disable outgoing email) -------------
echo "==> Disabling outgoing mail on staging ..."
if [[ -n "$PGPASSWORD_STAGE" ]]; then
  docker exec -e PGPASSWORD="${PGPASSWORD_STAGE}" -i "${SDB}" \
    psql -U "${DB_USER_STAGE}" -d "${DB_NAME_STAGE}" -v ON_ERROR_STOP=1 \
    -c "UPDATE ir_mail_server SET active=false;" || true
else
  docker exec -i "${SDB}" \
    psql -U "${DB_USER_STAGE}" -d "${DB_NAME_STAGE}" -v ON_ERROR_STOP=1 \
    -c "UPDATE ir_mail_server SET active=false;" || true
fi

#------------- start staging app back -------------
echo "==> Starting staging app ..."
docker start "$SOD" >/dev/null

echo "[✓] Staging successfully cloned from: $BACKUP_PATH"
