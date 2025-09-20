#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?Usage: restore_docker.sh <prod|staging> <backup.tgz> [NEW_DB_NAME] }"
ARCHIVE="${2:?Path to backup tar.gz required}"
NEWDB="${3:-}"   # optional new db name (for test clones)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env.${ENV}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 2; }

# load env
set -a; source "$ENV_FILE"; set +a

DB_RESTORE="${NEWDB:-${DB_NAME}}"

TMP="${ROOT}/.tmp-restore-${ENV}-$$"
rm -rf "$TMP"; mkdir -p "$TMP"
tar -C "$TMP" -xzf "$ARCHIVE"

echo "==> Restoring DB to container: ${DB_CONT} db=${DB_RESTORE}"
docker exec -e PGPASSWORD="${PGPASSWORD}" "$DB_CONT" \
  psql -U "${DB_USER}" -p "${DB_PORT}" -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_RESTORE}';" || true

docker exec -e PGPASSWORD="${PGPASSWORD}" "$DB_CONT" \
  psql -U "${DB_USER}" -p "${DB_PORT}" -d postgres -tc \
  "SELECT 1 FROM pg_database WHERE datname='${DB_RESTORE}'" | grep -q 1 && \
  docker exec -e PGPASSWORD="${PGPASSWORD}" "$DB_CONT" \
    psql -U "${DB_USER}" -p "${DB_PORT}" -d postgres -c "DROP DATABASE ${DB_RESTORE}" || true

docker exec -e PGPASSWORD="${PGPASSWORD}" "$DB_CONT" \
  createdb -U "${DB_USER}" -p "${DB_PORT}" "${DB_RESTORE}"

docker cp "${TMP}/db.dump" "${DB_CONT}:/tmp/db.dump"
docker exec -e PGPASSWORD="${PGPASSWORD}" "$DB_CONT" \
  pg_restore -U "${DB_USER}" -p "${DB_PORT}" -d "${DB_RESTORE}" /tmp/db.dump
docker exec "$DB_CONT" rm -f /tmp/db.dump || true

echo "==> Restoring filestore into app container: ${APP_CONT}"
DST="${FILESTORE_IN_APP%/*}/${DB_RESTORE}"
docker exec "$APP_CONT" mkdir -p "${DST}"
docker cp "${TMP}/filestore/." "${APP_CONT}:/tmp/filestore_in"
docker exec "$APP_CONT" bash -lc "rsync -a /tmp/filestore_in/ '${DST}/' && rm -rf /tmp/filestore_in"

rm -rf "$TMP"
echo "Restore completed to DB: ${DB_RESTORE}"
