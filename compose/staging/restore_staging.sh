#!/usr/bin/env bash
set -euo pipefail

BACKUP_TGZ="${1:?Usage: $0 /home/github-runner/backups/}"
DB_CONT="odoo-staging-db"
APP_CONT="odoo-staging-app"
DB_NAME="odoo_staging"

REST="$(mktemp -d /tmp/odoo-restore.XXXXXX)"
trap 'rm -rf "$REST"' EXIT

echo ">> Extracting $BACKUP_TGZ"
tar -xzf "$BACKUP_TGZ" -C "$REST"

echo ">> Detecting DB file"
DBFILE=""
if compgen -G "$REST/db/*.dump" > /dev/null; then
  DBFILE="$(ls -1 "$REST"/db/*.dump | head -1)"
  TYPE="dump"
elif compgen -G "$REST/db/*.sql" > /dev/null; then
  DBFILE="$(ls -1 "$REST"/db/*.sql | head -1)"
  TYPE="sql"
else
  echo "No db/*.dump or db/*.sql found"; exit 2
fi
echo "   Found $DBFILE ($TYPE)"

echo ">> Recreate DB and extensions"
docker exec -it "$DB_CONT" bash -lc "
  set -euo pipefail
  : \"\${POSTGRES_USER:?missing}\"
  psql -U \"\$POSTGRES_USER\" -d postgres -c \"DROP DATABASE IF EXISTS \\\"$DB_NAME\\\";\"
  psql -U \"\$POSTGRES_USER\" -d postgres -c \"CREATE DATABASE \\\"$DB_NAME\\\" OWNER \\\"\$POSTGRES_USER\\\" TEMPLATE template0 ENCODING 'UTF8';\"
  psql -U \"\$POSTGRES_USER\" -d \"$DB_NAME\" -c \"CREATE EXTENSION IF NOT EXISTS unaccent;\"
  psql -U \"\$POSTGRES_USER\" -d \"$DB_NAME\" -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\"
"

echo ">> Restore DB"
if [[ "$TYPE" == "dump" ]]; then
  docker cp "$DBFILE" "$DB_CONT":/tmp/odoo.dump
  docker exec -it "$DB_CONT" bash -lc '
    set -euo pipefail
    : "${POSTGRES_USER:?missing}"
    : "${POSTGRES_DB:=odoo_staging}"
    pg_restore --username="$POSTGRES_USER" --dbname="'"$DB_NAME"'" \
      --clean --if-exists --no-owner --no-privileges /tmp/odoo.dump
  '
else
  docker cp "$DBFILE" "$DB_CONT":/tmp/odoo.sql
  docker exec -it "$DB_CONT" bash -lc '
    set -euo pipefail
    : "${POSTGRES_USER:?missing}"
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "'"$DB_NAME"'" -f /tmp/odoo.sql
  '
fi

echo ">> Restore filestore"
if [[ -d "$REST/filestore" ]]; then
  SRC="$(find "$REST/filestore" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
  if [[ -n "$SRC" ]]; then
    docker exec -it "$APP_CONT" bash -lc "mkdir -p /var/lib/odoo/filestore/$DB_NAME"
    docker cp "$SRC"/. "$APP_CONT":/var/lib/odoo/filestore/"$DB_NAME"/
    docker exec -it "$APP_CONT" bash -lc "chown -R odoo:odoo /var/lib/odoo/filestore/$DB_NAME"
  else
    echo "   (no filestore dir found)"
  fi
else
  echo "   (no filestore in bundle)"
fi

echo ">> Done. Start app if stopped."
