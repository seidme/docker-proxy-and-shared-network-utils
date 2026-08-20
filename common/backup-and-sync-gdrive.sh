#!/bin/bash
set -e

BACKUP_DIR="/var/www/scout/db/backups"
DATE=$(date +%F)
BACKUP_FILE="${BACKUP_DIR}/Scout2DB-AB-${DATE}.sql.gz"
RCLONE_BIN="/home/seidme/.local/bin/rclone"
GDRIVE_REMOTE="gdrive:_dev/dbs/autobackups"

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Starting automated database backup ==="

# 1. Kreiraj svježi kompresovani backup baze
/usr/bin/docker exec -e PGPASSWORD="7Hjdf4l#-cqYeD89@-wapKe34=-er5Tfv3!" postgresdb pg_dump -U postgres Scout2DB 2>/dev/null | gzip > "$BACKUP_FILE"

# 2. Provjera veličine novog backupa
FILE_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo 0)
if [ ! -s "$BACKUP_FILE" ] || [ "$FILE_SIZE" -lt 1048576 ]; then
    echo "ERROR: Backup file is missing or smaller than 1MB!"
    /usr/bin/python3 /var/www/common/server-health-check.py || true
    exit 1
fi

echo "New backup created successfully: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

# 3. Ako je rclone konfigurisan, uploadaj samo ovaj novi backup na Google Drive
if "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^gdrive:"; then
    echo "=== Uploading new backup to Google Drive ($GDRIVE_REMOTE) ==="
    "$RCLONE_BIN" copyto "$BACKUP_FILE" "$GDRIVE_REMOTE/$(basename "$BACKUP_FILE")" --log-level NOTICE
    
    echo "Google Drive upload finished successfully."
    
    # 4. Nakon uspješnog uploada, obriši SAMO prethodni automatski backup (ne sve ostale)
    AUTO_BACKUPS=($(ls -t "$BACKUP_DIR"/Scout2DB-AB-*.sql* 2>/dev/null || true))
    
    if [ ${#AUTO_BACKUPS[@]} -ge 2 ]; then
        PREV_BACKUP="${AUTO_BACKUPS[1]}"
        if [ -f "$PREV_BACKUP" ] && [ "$PREV_BACKUP" != "$BACKUP_FILE" ]; then
            echo "Deleting only the previous automatic backup: $PREV_BACKUP"
            rm -f "$PREV_BACKUP"
        fi
    fi
else
    echo "NOTICE: 'gdrive' remote is not yet configured in rclone."
fi

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Backup process completed successfully ==="
