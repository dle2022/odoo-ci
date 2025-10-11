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
  ODOO_SERVICE_NAME="odoo"
else
  ENV_FILE="${PROJECT_DIR}/.env.staging"
  COMPOSE_FILE="${PROJECT_DIR}/compose/staging/docker-compose.yml"
  CONF_OUT="${PROJECT_DIR}/odoo/config/odoo.staging.conf"
  ODOO_SERVICE_NAME="odoo"   # change if your staging service name differs
fi

# ----- Guard rails -----
[[ -f "${ENV_FILE}" ]] || { echo "❌ Missing ${ENV_FILE}"; exit 2; }
[[ -f "${COMPOSE_FILE}" ]] || { echo "❌ Missing ${COMPOSE_FILE}"; exit 2; }

# >>> NEW: sanitize env file to avoid bad lines (e.g., '****') and CRLF
SAN_ENV="${ENV_FILE}.san"
# normalize CRLF -> LF (safe no-op on LF files)
sed 's/\r$//' "${ENV_FILE}" \
| awk 'BEGIN{FS="="}
       /^[[:space:]]*#/ {print; next}                  # keep comments
       /^[[:space:]]*$/ {next}                         # skip blank
       /^[A-Za-z_][A-Za-z0-9_]*=/ {print; next}        # keep KEY=VALUE
       { /* drop everything else */ }' > "${SAN_ENV}"

# ----- Load env (used by template rendering) -----
set -a; source "${SAN_ENV}"; set +a

# >>> NEW: minimal required vars (fail early if missing)
: "${ODOO_VERSION:?set ODOO_VERSION in ${ENV_FILE}}"
#: "${POSTGRES_DB:?set POSTGRES_DB in ${ENV_FILE}}"
: "${POSTGRES_USER:?set POSTGRES_USER in ${ENV_FILE}}"
: "${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in ${ENV_FILE}}"
# prefer explicit DB_NAME, else POSTGRES_DB if provided, else odoo_<env>
DB_NAME="${DB_NAME:-${POSTGRES_DB:-odoo_${ENV}}}"
# >>> NEW: provide defaults for DB_NAME if not set
: "${DB_NAME:=${POSTGRES_DB:-odoo_${ENV}}}"

# ----- Render odoo.conf from template -----
TEMPLATE="${PROJECT_DIR}/odoo/config/odoo.conf.tmpl"
command -v envsubst >/dev/null || { echo "❌ Install gettext-base for envsubst"; exit 3; }
mkdir -p "$(dirname "${CONF_OUT}")"
envsubst < "${TEMPLATE}" > "${CONF_OUT}"
echo "✅ Rendered ${CONF_OUT}"

# ----- Preflight: YAML tabs/CRLF & validate compose -----
if grep -nP $'\t' "${COMPOSE_FILE}" >/dev/null 2>&1; then
  echo "❌ Tabs detected in ${COMPOSE_FILE}. Replace tabs with spaces."
  exit 4
fi
if file "${COMPOSE_FILE}" | grep -qi "CRLF"; then
  echo "ℹ️ Converting CRLF to LF in ${COMPOSE_FILE}"
  sed -i 's/\r$//' "${COMPOSE_FILE}"
fi
if ! docker compose -f "${COMPOSE_FILE}" config >/dev/null; then
  echo "❌ Compose validation failed for ${COMPOSE_FILE}"
  docker compose -f "${COMPOSE_FILE}" config || true
  exit 5
fi

# ----- Pull + Up for selected env -----
echo "⬇️  Pulling images for ${ENV}…"
docker compose -f "${COMPOSE_FILE}" pull

echo "🚀 Starting ${ENV}…"
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

# ----- Optional: -u all -----
if [[ "${NO_UPDATE}" != "--no-update" ]]; then
  echo "🔧 Applying Odoo -u all on DB '${DB_NAME}' for ${ENV}…"
  if docker compose -f "${COMPOSE_FILE}" ps "${ODOO_SERVICE_NAME}" >/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" exec -T "${ODOO_SERVICE_NAME}" \
      odoo -c /etc/odoo/odoo.conf -d "${DB_NAME}" -u all --stop-after-init || true
  else
    docker compose -f "${COMPOSE_FILE}" run --rm "${ODOO_SERVICE_NAME}" \
      odoo -c /etc/odoo/odoo.conf -d "${DB_NAME}" -u all --stop-after-init || true
  fi
fi

echo "✅ Done. ${ENV} is up."

# ----- Non-fatal health ping -----
if command -v curl >/dev/null 2>&1; then
  if [[ "${ENV}" == "staging" && -n "${ODOO_BASE_URL_STAGING:-}" ]]; then
    curl -fsS "${ODOO_BASE_URL_STAGING%/}/web/login" >/dev/null && echo "🌐 Staging responds." || echo "⚠️ Staging not responding yet."
  elif [[ "${ENV}" == "prod" && -n "${ODOO_BASE_URL_PROD:-}" ]]; then
    curl -fsS "${ODOO_BASE_URL_PROD%/}/web/login" >/dev/null && echo "🌐 Prod responds." || echo "⚠️ Prod not responding yet."
  fi
fi
