#!/bin/bash
set -euo pipefail

# Where backups will be stored
BACKUP_ROOT=${BACKUP_ROOT:-/srv/backups}

TARGET=${1:-prod}   # prod or staging
DATE=$(date +%Y%m%d_%H%M%S)
FILENAME="${BACKUP_ROOT}/${TARGET}_odoo_${DATE}.tar.gz"

echo "==> Backing up ${TARGET} to ${FILENAME}"

# Example: adjust container names if needed
APP_CONT="odoo-${TARGET}-app"
DB_CONT="odoo-${TARGET}-db"

# Dump DB
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD $DB_CONT \
  pg_dump -U $POSTGRES_USER $DB_NAME > /tmp/db.dump

# Copy filestore
docker cp $APP_CONT:/var/lib/odoo/filestore /tmp/filestore

# Pack it up
tar -czf "$FILENAME" -C /tmp db.dump filestore

rm -rf /tmp/db.dump /tmp/filestore

echo "BACKUP_PATH=$FILENAME"
