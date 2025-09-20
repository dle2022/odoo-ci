#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/backup_docker.sh prod
#   ./scripts/backup_docker.sh staging
#   ./scripts/backup_docker.sh .env.custom   # optional direct file

ARG="${1:-prod}"

# Resolve env file from argument
if [[ "$ARG" == "prod" ]]; then
  ENV_FILE=".env.prod"
elif [[ "$ARG" == "staging" ]]; then
  ENV_FILE=".env.staging"
else
  ENV_FILE="$ARG"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# Validate required vars
: "${APP_CONT:?APP_CONT missing}"
: "${DB_CONT:?DB_CONT missing}"
: "${DB_NAME:?DB_NAME missing}"
: "${DB_USER:?DB_USER missing}"
: "${FILESTORE_IN_APP:?FILESTORE_IN_APP missing}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

STAMP="$(date +'%Y%m%d-%H%M%S')"
OUT_DIR="${BACKUP_ROOT}/${STAMP}"
mkdir -p "$OUT_DIR"

echo "[*] Backup start -> ${OUT_DIR}"

# 1) Backup Postgres roles/globals (optional but recommended)
if docker exec "$DB_CONT" bash -lc "command -v pg_dumpall >/dev/null 2>&1"; then
  echo "  - Dumping Postgres globals (roles)"
  docker exec -e PGPASSWORD="${PGPASSWORD:-}" "$DB_CONT" \
    pg_dumpall -U "$DB_USER" -g | gzip > "${OUT_DIR}/globals.sql.gz"
else
  echo "  - Skip globals: pg_dumpall not available in container"
fi

# 2) Backup specific DB
echo "  - Dumping database: ${DB_NAME}"
docker exec -e PGPASSWORD="${PGPASSWORD:-}" "$DB_CONT" \
  pg_dump -U "$DB_USER" -d "$DB_NAME" -F p --no-owner --no-privileges \
  | gzip > "${OUT_DIR}/${DB_NAME}.sql.gz"

# 3) Backup filestore from app container
echo "  - Archiving filestore from ${APP_CONT}:${FILESTORE_IN_APP}"
docker exec "$APP_CONT" bash -lc "tar -C / -czf - \"${FILESTORE_IN_APP#/}\"" \
  > "${OUT_DIR}/filestore.tar.gz"

# 4) Optional: backup extra addons if present
if docker exec "$APP_CONT" bash -lc "test -d /mnt/extra-addons"; then
  echo "  - Archiving /mnt/extra-addons"
  docker exec "$APP_CONT" bash -lc "tar -C / -czf - mnt/extra-addons" \
    > "${OUT_DIR}/addons.tar.gz"
fi

# 5) Write a manifest
cat > "${OUT_DIR}/manifest.txt" <<EOF
timestamp=${STAMP}
db_name=${DB_NAME}
app_container=${APP_CONT}
db_container=${DB_CONT}
filestore=${FILESTORE_IN_APP}
EOF

# 6) Retention
if [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
  echo "  - Enforcing retention: ${RETENTION_DAYS} days"
  find "${BACKUP_ROOT}" -maxdepth 1 -type d -name '20*' -mtime +${RETENTION_DAYS} -print -exec rm -rf {} \; || true
fi

echo "  - Listing output:"
ls -lh "${OUT_DIR}"

# IMPORTANT: print a machine-parsable line for the GitHub step output
echo "BACKUP_PATH=${OUT_DIR}"
echo "[✓] Backup complete"
