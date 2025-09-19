#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: $0 [staging|prod] [--no-update]"; exit 1; }

ENV="${1:-}"; [[ -z "${ENV}" ]] && usage
[[ "${ENV}" != "staging" && "${ENV}" != "prod" ]] && usage
NO_UPDATE="${2:-}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${ENV}" == "prod" ]]; then
  ENV_FILE="${PROJECT_DIR}/.env.prod"
  COMPOSE_FILE="${PROJECT_DIR}/compose/prod/docker-compose.yml"
  CONF_OUT="${PROJECT_DIR}/odoo/config/odoo.prod.conf"
else
  ENV_FILE="${PROJECT_DIR}/.env.staging"
  COMPOSE_FILE="${PROJECT_DIR}/compose/staging/docker-compose.yml"
  CONF_OUT="${PROJECT_DIR}/odoo/config/odoo.staging.conf"
fi

[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE}"; exit 2; }

set -a; source "${ENV_FILE}"; set +a

TEMPLATE="${PROJECT_DIR}/odoo/config/odoo.conf.tmpl"
command -v envsubst >/dev/null || { echo "Install gettext-base for envsubst"; exit 3; }
envsubst < "${TEMPLATE}" > "${CONF_OUT}"
echo "Rendered ${CONF_OUT}"

docker compose -f "${COMPOSE_FILE}" pull
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

if [[ "${NO_UPDATE}" != "--no-update" ]]; then
  echo "Applying Odoo -u all on ${DB_NAME} ..."
  docker compose -f "${COMPOSE_FILE}" exec -T odoo \
    odoo -c /etc/odoo/odoo.conf -d "${DB_NAME}" -u all --stop-after-init || true
fi

echo "Done. ${ENV} is up."
