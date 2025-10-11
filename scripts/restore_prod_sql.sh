#!/usr/bin/env bash
set -euo pipefail

# Restore PRODUCTION from a prod SQL bundle (db.sql.gz + filestore.tgz)
# Usage:
#   scripts/restore_prod_sql.sh --from /abs/path/to/prod_...tar.gz
#   scripts/restore_prod_sql.sh --date 20251006         # fuzzy: 2025-10-06 also works
#
# Relies on: .env.backup.prod (preferred) or .env.prod

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKUP_PATH=""
DATE_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)  shift; BACKUP_PATH="${1:-}";;
    --date)  shift; DATE_KEY="${1:-}";;
    -h|--help) echo "Usage: $0 (--from TAR | --date YYYYMMDD|YYYY-MM-DD)"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
  shift
done

# ---------- env detection ----------
PROD_ENV_FILE="$([[ -f "${PROJECT_DIR}/.env.backup.prod" ]] && echo "${PROJECT_DIR}/.env.backup.prod" || echo "${PROJECT_DIR}/.env.prod")"
[[ -f "$PROD_ENV_FILE" ]] || { echo "Missing $PROD_ENV_FILE"; exit 2; }
set -a; source <(sed -e 's/\r$//' "$PROD_ENV_FILE"); set +a

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"
APP_CONT="${APP_CONT:-odoo-prod-app}"
DB_CONT="${DB_CONT:-odoo-prod-db}"
DB_USER="${DB_USER:-${POSTGRES_USER:-odoo}}"
PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"
DB_NAME="${DB_NAME:-${POSTGRES_DB:-odoo_prod}}"

# Filestore path normalization
if [[ -z "${FILESTORE_IN_APP:-}" ]]; then
  FILESTORE_IN_APP="/var/lib/odoo/.local/share/Odoo/filestore/${DB_NAME}"
else
  case "$FILESTORE_IN_APP" in
    */filestore)   FILESTORE_IN_APP="${FILESTORE_IN_APP}/${DB_NAME}";;
    */filestore/)  FILESTORE_IN_APP="${FILESTORE_IN_APP}${DB_NAME}";;
    */)            FILESTORE_IN_APP="${FILESTORE_IN_APP}${DB_NAME}";;
  esac
fi

# ---------- choose backup ----------
if [[ -z "$BACKUP_PATH" ]]; then
  [[ -n "$DATE_KEY" ]] || { echo "Provide --from or --date"; exit 3; }
  DATE_KEY_FLAT="$(echo "$DATE_KEY" | tr -d '-')"
  BACKUP_PATH="$(ls -1t "${BACKUP_ROOT}/prod_odoo_${DB_NAME}_"*".tar.gz" 2>/dev/null | grep -m1 -E "${DATE_KEY_FLAT}|${DATE_KEY}" || true)"
  [[ -n "$BACKUP_PATH" && -f "$BACKUP_PATH" ]] || { echo "No backup tar found for date key: $DATE_KEY in $BACKUP_ROOT"; exit 4; }
fi

[[ -f "$BACKUP_PATH" ]] || { echo "Backup tar not found: $BACKUP_PATH"; exit 5; }
echo "==> Using backup: $BACKUP_PATH"

# quick sanity: must contain db.sql(.gz)
if ! tar -tzf "$BACKUP_PATH" | grep -Eq '(^|/)db\.sql(\.gz)?$'; then
  echo "Selected tarball does not contain db.sql(.gz)"; exit 6
fi

# ---------- extract to temp ----------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" || true' EXIT
tar -C "$WORK_DIR" -xzf "$BACKUP_PATH"

SQL_FILE=""
if [[ -f "$WORK_DIR/db.sql.gz" ]]; then
  SQL_FILE="db.sql.gz"
elif [[ -f "$WORK_DIR/db.sql" ]]; then
  SQL_FILE="db.sql"
else
  echo "db.sql(.gz) missing after extract"; exit 7
fi

[[ -f "$WORK_DIR/filestore.tgz" ]] || echo "WARN: filestore.tgz missing (DB-only restore)"

# ---------- stop app to avoid races ----------
docker stop "$APP_CONT" >/dev/null 2>&1 || true

# ---------- recreate DB + required extensions ----------
echo "==> Recreating DB '${DB_NAME}' ..."
if [[ -n "$PGPASSWORD" ]]; then
  docker exec -e PGPASSWORD="$PGPASSWORD" -i "$DB_CONT" \
    psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}';" || true
  docker exec -e PGPASSWORD="$PGPASSWORD" -i "$DB_CONT" \
    psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";"
  docker exec -e PGPASSWORD="$PGPASSWORD" -i "$DB_CONT" \
    psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\" TEMPLATE template0 ENCODING 'UTF8';"
  docker exec -e PGPASSWORD="$PGPASSWORD" -i "$DB_CONT" \
    psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION IF NOT EXISTS unaccent;"
  docker exec -e PGPASSWORD="$PGPASSWORD" -i "$DB_CONT" \
    psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
else
  docker exec -i "$DB_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}';" || true
  docker exec -i "$DB_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";"
  docker exec -i "$DB_CONT" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\" TEMPLATE template0 ENCODING 'UTF8';"
  docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION IF NOT EXISTS unaccent;"
  docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
fi

# ---------- restore SQL ----------
echo "==> Restoring SQL (${SQL_FILE}) ..."
if [[ "$SQL_FILE" == "db.sql.gz" ]]; then
  docker cp "$WORK_DIR/db.sql.gz" "$DB_CONT:/tmp/db.sql.gz"
  if [[ -n "$PGPASSWORD" ]]; then
    docker exec -e PGPASSWORD="$PGPASSWORD" -i "$DB_CONT" \
      bash -lc 'gunzip -c /tmp/db.sql.gz | psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "'"$DB_NAME"'"'
  else
    docker exec -i "$DB_CONT" \
      bash -lc 'gunzip -c /tmp/db.sql.gz | psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "'"$DB_NAME"'"'
  fi
  docker exec "$DB_CONT" bash -lc "rm -f /tmp/db.sql.gz"
else
  docker cp "$WORK_DIR/db.sql" "$DB_CONT:/tmp/db.sql"
  if [[ -n "$PGPASSWORD" ]]; then
    docker exec -e PGPASSWORD="$PGPASSWORD" -i "$DB_CONT" \
      psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -f /tmp/db.sql
  else
    docker exec -i "$DB_CONT" \
      psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -f /tmp/db.sql
  fi
  docker exec "$DB_CONT" bash -lc "rm -f /tmp/db.sql"
fi

# ---------- helper: ensure app container is running ----------
ensure_app_running() {
  local c="$1"
  if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)" != "true" ]]; then
    echo "==> App container '$c' is stopped; starting it …"
    docker start "$c" >/dev/null
    # short wait to avoid race
    for _ in {1..15}; do
      [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)" == "true" ]] && break
      sleep 1
    done
  fi
}

# ---------- restore filestore (as root) ----------
if [[ -f "$WORK_DIR/filestore.tgz" ]]; then
  echo "==> Restoring filestore -> ${FILESTORE_IN_APP}"
  ensure_app_running "$APP_CONT"

  # Always clear any stale temp file first (root)
  docker exec -u 0 -i "$APP_CONT" bash -lc "rm -f /tmp/filestore.tgz || true"

  # Prepare target dir and empty it (root)
  docker exec -u 0 -i "$APP_CONT" bash -lc "
    set -euo pipefail
    mkdir -p '$FILESTORE_IN_APP'
    rm -rf '$FILESTORE_IN_APP'/* || true
  "

  # Copy and unpack as root, fix ownership, remove temp
  docker cp "$WORK_DIR/filestore.tgz" "$APP_CONT:/tmp/filestore.tgz"
  docker exec -u 0 -i "$APP_CONT" bash -lc "
    set -euo pipefail
    tar -xzf /tmp/filestore.tgz -C '$FILESTORE_IN_APP'
    chown -R odoo:odoo '$FILESTORE_IN_APP'
    rm -f /tmp/filestore.tgz || true
  "
fi

# ---------- final start ----------
echo "==> Starting Odoo prod app ..."
docker start "$APP_CONT" >/dev/null
echo "[✓] Production restored from: $BACKUP_PATH"
