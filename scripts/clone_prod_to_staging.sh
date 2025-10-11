#!/usr/bin/env bash
# Usage: ./scripts/clone_prod_to_staging.sh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set -a
source "${PROJECT_DIR}/.env.prod";   PROD_DB="${DB_NAME}"
source "${PROJECT_DIR}/.env.staging"; STAGE_DB="${DB_NAME}"
set +a

PROD_COMPOSE="${PROJECT_DIR}/compose/prod/docker-compose.yml"
STAGE_COMPOSE="${PROJECT_DIR}/compose/staging/docker-compose.yml"

PDB=$(docker compose -f "${PROD_COMPOSE}" ps -q db)
POD=$(docker compose -f "${PROD_COMPOSE}" ps -q odoo)
SDB=$(docker compose -f "${STAGE_COMPOSE}" ps -q db)
SOD=$(docker compose -f "${STAGE_COMPOSE}" ps -q odoo)

echo "Dumping Production DB (${PROD_DB}) ..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${PDB}" \
  pg_dump -U "${POSTGRES_USER}" "${PROD_DB}" > /tmp/prod_db.sql

echo "Restoring into Staging (${STAGE_DB}) ..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${SDB}" \
  psql -U "${POSTGRES_USER}" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${STAGE_DB}';" || true
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${SDB}" \
  psql -U "${POSTGRES_USER}" -d postgres -c "DROP DATABASE IF EXISTS \"${STAGE_DB}\";"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${SDB}" \
  psql -U "${POSTGRES_USER}" -d postgres -c "CREATE DATABASE \"${STAGE_DB}\" OWNER \"${POSTGRES_USER}\";"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${SDB}" \
  psql -U "${POSTGRES_USER}" -d "${STAGE_DB}" < /tmp/prod_db.sql

echo "Syncing filestore ..."
docker exec "${SOD}" bash -lc "rm -rf /var/lib/odoo/.local/share/Odoo/filestore/${STAGE_DB} || true"
docker exec "${SOD}" bash -lc "mkdir -p /var/lib/odoo/.local/share/Odoo/filestore"
docker cp "${POD}:/var/lib/odoo/.local/share/Odoo/filestore/${PROD_DB}" \
  "${SOD}:/var/lib/odoo/.local/share/Odoo/filestore/${STAGE_DB}"

echo "Sanitizing Staging (disable outgoing mail servers) ..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${SDB}" \
  psql -U "${POSTGRES_USER}" -d "${STAGE_DB}" -c "UPDATE ir_mail_server SET active = false;" || true

echo "Done. Staging is refreshed from Production."
