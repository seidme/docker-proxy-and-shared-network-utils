#!/bin/bash
set -e

BACKUP_DIR="/var/www/scout/db/backups"
DATE=$(date +%F)
BACKUP_FILE="${BACKUP_DIR}/Scout2DB-AB-${DATE}.sql.gz"
RCLONE_BIN="/home/seidme/.local/bin/rclone"
GDRIVE_REMOTE="gdrive:ServerBackups/Scout2DB"

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

echo "Backup created successfully: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

# 3. Ako je rclone konfigurisan, pošalji na Google Drive
if "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^gdrive:"; then
    echo "=== Syncing backups to Google Drive ($GDRIVE_REMOTE) ==="
    "$RCLONE_BIN" copy "$BACKUP_DIR" "$GDRIVE_REMOTE" --include "Scout2DB-AB-*.sql*" --log-level NOTICE
    
    echo "Google Drive sync finished successfully."
    
    # 4. Nakon potvrđenog uploada na Google Drive, obriši starije lokalne backupe sa servera (ostavi samo zadnji kreirani!)
    echo "Cleaning older local backups (keeping only the latest on server)..."
    ls -t "$BACKUP_DIR"/Scout2DB-AB-*.sql* 2>/dev/null | tail -n +2 | xargs -r rm -f
    echo "Local disk space optimized: only latest backup retained on server."
else
    echo "NOTICE: 'gdrive' remote is not yet configured in rclone. Keeping standard 7-day retention locally."
    find "$BACKUP_DIR" -name "*AB-*.sql*" -mtime +7 -delete
fi

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Backup process completed successfully ==="
