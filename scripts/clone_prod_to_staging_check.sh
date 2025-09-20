#!/usr/bin/env bash
# Clone Production Odoo (DB + filestore) to Staging, safely.
# Usage: ./scripts/clone_prod_to_staging.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

#----- Load envs and NAMESPACE them so prod/stage never collide
# Load PROD env then capture values we need, before sourcing staging.
set -a
source "${PROJECT_DIR}/.env.prod"
# Required (prod)
PROD_DB_NAME="${DB_NAME:?DB_NAME missing in .env.prod}"
PROD_DB_USER="${DB_USER:-${POSTGRES_USER:-postgres}}"
PROD_DB_PASS="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"
PROD_FILESTORE="${FILESTORE_IN_APP:-/var/lib/odoo/.local/share/Odoo/filestore/${PROD_DB_NAME}}"
set +a

# Load STAGING env and capture
set -a
source "${PROJECT_DIR}/.env.staging"
# Required (stage)
STAGE_DB_NAME="${DB_NAME:?DB_NAME missing in .env.staging}"
STAGE_DB_USER="${DB_USER:-${POSTGRES_USER:-postgres}}"
STAGE_DB_PASS="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"
STAGE_FILESTORE="${FILESTORE_IN_APP:-/var/lib/odoo/.local/share/Odoo/filestore/${STAGE_DB_NAME}}"
set +a

# Compose files (adjust paths if your repo differs)
PROD_COMPOSE="${PROJECT_DIR}/compose/prod/docker-compose.yml"
STAGE_COMPOSE="${PROJECT_DIR}/compose/staging/docker-compose.yml"

#----- Resolve container IDs (services must be named "db" and "odoo" in each compose)
PDB="$(docker compose -f "${PROD_COMPOSE}" ps -q db)"
POD="$(docker compose -f "${PROD_COMPOSE}" ps -q odoo)"
SDB="$(docker compose -f "${STAGE_COMPOSE}" ps -q db)"
SOD="$(docker compose -f "${STAGE_COMPOSE}" ps -q odoo)"

# Basic sanity
[[ -n "$PDB" && -n "$POD" && -n "$SDB" && -n "$SOD" ]] || {
  echo "ERROR: Could not resolve one or more containers.
  PROD db=$PDB, PROD odoo=$POD, STAGE db=$SDB, STAGE odoo=$SOD
  Check service names in compose files (expect: db, odoo) and that both stacks are up." >&2
  exit 2
}

echo "==> Cloning PROD -> STAGING"
echo "    PROD db: $PDB  user: ${PROD_DB_USER}  db: ${PROD_DB_NAME}"
echo "    STAGE db: $SDB user: ${STAGE_DB_USER} db: ${STAGE_DB_NAME}"
echo "    Filestore: ${PROD_FILESTORE}  -->  ${STAGE_FILESTORE}"

#----- Stop staging Odoo to avoid writes during restore
echo "==> Stopping staging app container to freeze writes ..."
docker stop "$SOD" >/dev/null

#----- Dump PROD database (to host /tmp, plain SQL for max compatibility)
DB_DUMP="/tmp/prod_db_$$.sql"
trap 'rm -f "$DB_DUMP" || true' EXIT

echo "==> Dumping PROD DB '${PROD_DB_NAME}' ..."
if [[ -n "$PROD_DB_PASS" ]]; then
  docker exec -e PGPASSWORD="${PROD_DB_PASS}" -i "${PDB}" \
    pg_dump -U "${PROD_DB_USER}" -d "${PROD_DB_NAME}" \
    --no-owner --no-privileges > "${DB_DUMP}"
else
  docker exec -i "${PDB}" \
    pg_dump -U "${PROD_DB_USER}" -d "${PROD_DB_NAME}" \
    --no-owner --no-privileges > "${DB_DUMP}"
fi
[[ -s "${DB_DUMP}" ]] || { echo "ERROR: PROD dump is empty."; exit 3; }

#----- Recreate STAGING database and restore dump
echo "==> Recreating STAGING DB '${STAGE_DB_NAME}' and restoring ..."
if [[ -n "$STAGE_DB_PASS" ]]; then
  docker exec -e PGPASSWORD="${STAGE_DB_PASS}" -i "${SDB}" \
    psql -U "${STAGE_DB_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${STAGE_DB_NAME}';" || true
  docker exec -e PGPASSWORD="${STAGE_DB_PASS}" -i "${SDB}" \
    psql -U "${STAGE_DB_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${STAGE_DB_NAME}\";"
  docker exec -e PGPASSWORD="${STAGE_DB_PASS}" -i "${SDB}" \
    psql -U "${STAGE_DB_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"${STAGE_DB_NAME}\" OWNER \"${STAGE_DB_USER}\";"
  docker exec -e PGPASSWORD="${STAGE_DB_PASS}" -i "${SDB}" \
    psql -U "${STAGE_DB_USER}" -d "${STAGE_DB_NAME}" -v ON_ERROR_STOP=1 < "${DB_DUMP}"
else
  docker exec -i "${SDB}" psql -U "${STAGE_DB_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${STAGE_DB_NAME}';" || true
  docker exec -i "${SDB}" psql -U "${STAGE_DB_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${STAGE_DB_NAME}\";"
  docker exec -i "${SDB}" psql -U "${STAGE_DB_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"${STAGE_DB_NAME}\" OWNER \"${STAGE_DB_USER}\";"
  docker exec -i "${SDB}" psql -U "${STAGE_DB_USER}" -d "${STAGE_DB_NAME}" -v ON_ERROR_STOP=1 < "${DB_DUMP}"
fi

#----- Sync filestore using tar stream (container -> container)
echo "==> Syncing filestore from PROD to STAGING ..."
# Clean target first
docker exec "${SOD}" bash -lc "rm -rf '${STAGE_FILESTORE}' && mkdir -p '${STAGE_FILESTORE}'"
# Stream contents of PROD filestore into STAGE filestore
docker exec "${POD}" bash -lc "tar -C '${PROD_FILESTORE}' -cf - '.'" \
  | docker exec -i "${SOD}" bash -lc "tar -C '${STAGE_FILESTORE}' -xf -"

#----- Safety: disable outgoing mail on staging
echo "==> Disabling outgoing mail servers on STAGING ..."
if [[ -n "$STAGE_DB_PASS" ]]; then
  docker exec -e PGPASSWORD="${STAGE_DB_PASS}" -i "${SDB}" \
    psql -U "${STAGE_DB_USER}" -d "${STAGE_DB_NAME}" -v ON_ERROR_STOP=1 \
    -c "UPDATE ir_mail_server SET active = false;" || true
else
  docker exec -i "${SDB}" \
    psql -U "${STAGE_DB_USER}" -d "${STAGE_DB_NAME}" -v ON_ERROR_STOP=1 \
    -c "UPDATE ir_mail_server SET active = false;" || true
fi

#----- Start staging app back
echo "==> Starting staging app container ..."
docker start "$SOD" >/dev/null

echo "[✓] Done. Staging is refreshed from Production."
