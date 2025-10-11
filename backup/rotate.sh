#!/usr/bin/env bash
# Usage: rotate.sh [staging|prod] [N]
set -euo pipefail
ENV="${1:-prod}"
KEEP="${2:-7}"
BACKUP_ROOT="/srv/odoo/backups/${ENV}"
ls -1t "${BACKUP_ROOT}"/*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
echo "Kept ${KEEP} most recent backups in ${BACKUP_ROOT}."
