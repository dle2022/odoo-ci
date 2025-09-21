#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [staging|prod] [--no-update]"
  exit 1
}

ENV="${1:-}"; [[ -z "${ENV}" ]] && usage
[[ "${ENV}" != "staging" && "${ENV}" != "prod" ]] && usage
NO_UPDATE="${2:-}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ----- Resolve per-env files without changing prod behavior -----
if [[ "${ENV}" == "prod" ]]; then
  ENV_FILE="${PROJECT_DIR}/.env.prod"
  COMPOSE_FILE="${PROJECT_DIR}/compose/prod/docker-compose.yml"
  CONF_OUT="${PROJECT_DIR}/odoo/config/odoo.prod.conf"
  ODOO_SERVICE_NAME="odoo"            # keep as-is for prod
else
  ENV_FILE="${PROJECT_DIR}/.env.staging"
  COMPOSE_FILE="${PROJECT_DIR}/compose/staging/docker-compose.yml"
  CONF_OUT="${PROJECT_DIR}/odoo/config/odoo.staging.conf"
  ODOO_SERVICE_NAME="odoo"            # change if your staging service is named differently
fi

# ----- Guard rails: only proceed if the targeted env files exist -----
[[ -f "${ENV_FILE}" ]] || { echo "❌ Missing ${ENV_FILE}"; exit 2; }
[[ -f "${COMPOSE_FILE}" ]] || { echo "❌ Missing ${COMPOSE_FILE}"; exit 2; }

# ----- Load env (used by template rendering) -----
set -a; source "${ENV_FILE}"; set +a

# Provide a sane default for staging DB if not set (does not affect prod)
if [[ "${ENV}" == "staging" ]]; then
  : "${DB_NAME:=odoo_staging}"
fi

# ----- Render odoo.conf from template -----
TEMPLATE="${PROJECT_DIR}/odoo/config/odoo.conf.tmpl"
command -v envsubst >/dev/null || { echo "❌ Install gettext-base for envsubst"; exit 3; }
mkdir -p "$(dirname "${CONF_OUT}")"
envsubst < "${TEMPLATE}" > "${CONF_OUT}"
echo "✅ Rendered ${CONF_OUT}"

# ----- Preflight: catch YAML/tab/CRLF issues early -----
# Fail fast if there are tabs (YAML forbids tabs)
if grep -nP "\t" "${COMPOSE_FILE}" >/dev/null 2>&1; then
  echo "❌ Tabs detected in ${COMPOSE_FILE}. Replace tabs with spaces."
  exit 4
fi
# Warn/fix CRLF line endings (common after copy/paste from Windows)
if file "${COMPOSE_FILE}" | grep -qi "CRLF"; then
  echo "ℹ️ Converting CRLF to LF in ${COMPOSE_FILE}"
  sed -i 's/\r$//' "${COMPOSE_FILE}"
fi

# Validate the compose file before touching containers
if ! docker compose -f "${COMPOSE_FILE}" config >/dev/null; then
  echo "❌ Compose validation failed for ${COMPOSE_FILE}"
  echo "🔎 Details:"
  docker compose -f "${COMPOSE_FILE}" config || true
  exit 5
fi

# ----- Pull + Up only for the selected environment -----
echo "⬇️  Pulling images for ${ENV}…"
docker compose -f "${COMPOSE_FILE}" pull

echo "🚀 Starting ${ENV}…"
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

# ----- Optional: run -u all for the selected environment only -----
if [[ "${NO_UPDATE}" != "--no-update" ]]; then
  echo "🔧 Applying Odoo -u all on DB '${DB_NAME}' for ${ENV}…"
  # Use 'run --rm' if the service might not have TTY/exec available yet
  if docker compose -f "${COMPOSE_FILE}" ps "${ODOO_SERVICE_NAME}" >/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" exec -T "${ODOO_SERVICE_NAME}" \
      odoo -c /etc/odoo/odoo.conf -d "${DB_NAME}" -u all --stop-after-init || true
  else
    docker compose -f "${COMPOSE_FILE}" run --rm "${ODOO_SERVICE_NAME}" \
      odoo -c /etc/odoo/odoo.conf -d "${DB_NAME}" -u all --stop-after-init || true
  fi
fi

echo "✅ Done. ${ENV} is up."

# ----- Extra: quick health ping (non-fatal) -----
if command -v curl >/dev/null 2>&1; then
  if [[ "${ENV}" == "staging" && -n "${ODOO_BASE_URL_STAGING:-}" ]]; then
    curl -fsS "${ODOO_BASE_URL_STAGING%/}/web/login" >/dev/null && echo "🌐 Staging responds." || echo "⚠️ Staging not responding yet."
  elif [[ "${ENV}" == "prod" && -n "${ODOO_BASE_URL_PROD:-}" ]]; then
    curl -fsS "${ODOO_BASE_URL_PROD%/}/web/login" >/dev/null && echo "🌐 Prod responds." || echo "⚠️ Prod not responding yet."
  fi
fi
