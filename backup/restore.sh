#!/usr/bin/env bash
# Usage: restore.sh [staging|prod] /path/to/backup.tar.gz
set -euo pipefail
ENV="${1:-}"; ARCHIVE="${2:-}"
[[ -z "${ENV}" || -z "${ARCHIVE}" ]] && { echo "Usage: $0 [staging|prod] /path/to/backup.tar.gz"; exit 1; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${ENV}" == "prod" ]]; then
  ENV_FILE="${PROJECT_DIR}/.env.prod"
  COMPOSE_FILE="${PROJECT_DIR}/compose/prod/docker-compose.yml"
else
  ENV_FILE="${PROJECT_DIR}/.env.staging"
  COMPOSE_FILE="${PROJECT_DIR}/compose/staging/docker-compose.yml"
fi
set -a; source "${ENV_FILE}"; set +a

TMPDIR="$(mktemp -d)"
tar -xzf "${ARCHIVE}" -C "${TMPDIR}"
SNAPSHOT_DIR="$(find "${TMPDIR}" -maxdepth 1 -type d -name '20*' | head -n1)" || true
[[ -z "${SNAPSHOT_DIR}" ]] && { echo "Invalid archive"; exit 2; }

DB_CONT=$(docker compose -f "${COMPOSE_FILE}" ps -q db)
ODOO_CONT=$(docker compose -f "${COMPOSE_FILE}" ps -q odoo)

echo "Restoring DB ${DB_NAME} ..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${DB_CONT}" \
  psql -U "${POSTGRES_USER}" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}';" || true
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${DB_CONT}" \
  psql -U "${POSTGRES_USER}" -d postgres -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";"
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${DB_CONT}" \
  psql -U "${POSTGRES_USER}" -d postgres -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${POSTGRES_USER}\";"

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${DB_CONT}" \
  psql -U "${POSTGRES_USER}" -d "${DB_NAME}" < "${SNAPSHOT_DIR}/db.sql"

echo "Restoring filestore ..."
docker exec "${ODOO_CONT}" bash -lc "rm -rf /var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME} || true"
docker cp "${SNAPSHOT_DIR}/filestore" "${ODOO_CONT}:/var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME}"
docker exec "${ODOO_CONT}" bash -lc "chown -R odoo:odoo /var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME}"

echo "Restore complete."
