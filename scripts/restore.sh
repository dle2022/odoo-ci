#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?Usage: restore.sh <staging|prod> <backup.tgz> [NEW_DB_NAME] }"
ARCHIVE="${2:?Path to backup tar.gz required}"
NEWDB="${3:-}"  # Optional: restore under a different name

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.${ENV}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 2; }
set -a; source "$ENV_FILE"; set +a

DBNAME="${NEWDB:-${ODOO_DB}}"
export PGPASSWORD="${PGPASSWORD:-}"

TMP="${ROOT}/.tmp-restore"
rm -rf "$TMP"; mkdir -p "$TMP"
tar -C "$TMP" -xzf "$ARCHIVE"

# Optional: stop Odoo before restore (docker)
if [[ -f "${ROOT}/${COMPOSE_FILE:-}" ]]; then
  docker compose -f "${ROOT}/${COMPOSE_FILE}" stop "${ODOO_SERVICE:-odoo}" || true
fi

# Drop + recreate DB
psql -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DBNAME}';" || true
psql -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='${DBNAME}'" | grep -q 1 \
  && psql -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -d postgres -c "DROP DATABASE ${DBNAME}" || true
createdb -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" "${DBNAME}"
pg_restore -h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -d "${DBNAME}" "${TMP}/db.dump"

# Restore filestore
DST="/var/lib/odoo/.local/share/Odoo/filestore/${DBNAME}"
mkdir -p "${DST}"
rsync -a "${TMP}/filestore/" "${DST}/"
chown -R "${ODOO_USER:-odoo}:${ODOO_USER:-odoo}" "${DST}" || true

# Start Odoo back up
if [[ -f "${ROOT}/${COMPOSE_FILE:-}" ]]; then
  docker compose -f "${ROOT}/${COMPOSE_FILE}" up -d "${ODOO_SERVICE:-odoo}"
fi

rm -rf "$TMP"
echo "Restore completed to database: ${DBNAME}"
