#!/usr/bin/env bash
# Usage: backup.sh [staging|prod]
set -euo pipefail
ENV="${1:-}"; [[ -z "${ENV}" ]] && { echo "Usage: $0 [staging|prod]"; exit 1; }
[[ "${ENV}" != "staging" && "${ENV}" != "prod" ]] && { echo "ENV must be staging or prod"; exit 1; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${ENV}" == "prod" ]]; then
  ENV_FILE="${PROJECT_DIR}/.env.prod"
  COMPOSE_FILE="${PROJECT_DIR}/compose/prod/docker-compose.yml"
else
  ENV_FILE="${PROJECT_DIR}/.env.staging"
  COMPOSE_FILE="${PROJECT_DIR}/compose/staging/docker-compose.yml"
fi
set -a; source "${ENV_FILE}"; set +a

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="/srv/odoo/backups/${ENV}"
mkdir -p "${BACKUP_ROOT}/${TS}"

DB_CONT=$(docker compose -f "${COMPOSE_FILE}" ps -q db)
ODOO_CONT=$(docker compose -f "${COMPOSE_FILE}" ps -q odoo)

echo "Dumping DB ${DB_NAME} ..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" -i "${DB_CONT}" \
  pg_dump -U "${POSTGRES_USER}" "${DB_NAME}" > "${BACKUP_ROOT}/${TS}/db.sql"

echo "Copying filestore ..."
docker cp "${ODOO_CONT}:/var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME}" \
  "${BACKUP_ROOT}/${TS}/filestore"

tar -C "${BACKUP_ROOT}" -czf "${BACKUP_ROOT}/${TS}.tar.gz" "${TS}"
rm -rf "${BACKUP_ROOT:?}/${TS}"
echo "Backup: ${BACKUP_ROOT}/${TS}.tar.gz"
