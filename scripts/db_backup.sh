#!/bin/bash
# db_backup.sh
# Dumps the PostgreSQL database running in the postgres_db container,
# compresses it, and stores it with a timestamped filename.

set -euo pipefail

CONTAINER_NAME="postgres_db"
DB_NAME="appdb"
DB_USER="appuser"
BACKUP_DIR="/var/backups/db"
DATE_STAMP=$(date +%Y%m%d)
BACKUP_FILE="${BACKUP_DIR}/db_backup_${DATE_STAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "Starting backup of '${DB_NAME}' at $(date '+%Y-%m-%d %H:%M:%S')..."

docker exec -t "$CONTAINER_NAME" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"

if [ $? -eq 0 ] && [ -s "$BACKUP_FILE" ]; then
    echo "Backup successful: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
else
    echo "[ERROR] Backup failed."
    exit 1
fi

# Retention: keep only the last 7 daily backups
find "$BACKUP_DIR" -name "db_backup_*.sql.gz" -mtime +7 -exec rm {} \;
echo "Old backups (older than 7 days) cleaned up."
