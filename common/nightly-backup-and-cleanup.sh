#!/bin/bash
set -e

BACKUP_DIR="/var/www/scout/db/backups"
DATE=$(date +%F)
RCLONE_BIN="/home/seidme/.local/bin/rclone"
GDRIVE_REMOTE="gdrive:"
PG_PASS="7Hjdf4l#-cqYeD89@-wapKe34=-er5Tfv3!"

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Starting automated database backup check ==="

backup_database() {
    local DBNAME="$1"
    local BACKUP_FILE="${BACKUP_DIR}/${DBNAME}-AB-${DATE}.sql.gz"
    local STATE_FILE="${BACKUP_DIR}/.${DBNAME}.last_state"
    
    # Dobavi stanje promjena (commiti, inserti, updejti, deleti)
    local CURRENT_STATE=$(/usr/bin/docker exec -e PGPASSWORD="$PG_PASS" postgresdb psql -U postgres -Atc         "SELECT xact_commit || ':' || tup_inserted || ':' || tup_updated || ':' || tup_deleted FROM pg_stat_database WHERE datname = '$DBNAME';" 2>/dev/null || echo "")

    if [ -z "$CURRENT_STATE" ]; then
        echo "WARNING: Could not fetch database stats for '$DBNAME'. Proceeding with fallback backup."
    elif [ -f "$STATE_FILE" ] && [ "$CURRENT_STATE" == "$(cat "$STATE_FILE" 2>/dev/null)" ]; then
        echo "[$DBNAME] Nema novih izmjena u bazi od zadnjeg backupa ($CURRENT_STATE). Preskacem dump i upload."
        return 0
    fi

    echo "[$DBNAME] Detektovane nove izmjene (ili prvi run). Pokrecem backup..."
    
    # 1. Kreiraj kompresovani backup
    /usr/bin/docker exec -e PGPASSWORD="$PG_PASS" postgresdb pg_dump -U postgres "$DBNAME" 2>/dev/null | gzip > "$BACKUP_FILE"
    
    # 2. Provjera veličine (minimalno 1MB)
    local FILE_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo 0)
    if [ ! -s "$BACKUP_FILE" ] || [ "$FILE_SIZE" -lt 1048576 ]; then
        echo "ERROR: Backup file for '$DBNAME' is missing or smaller than 1MB!"
        /usr/bin/python3 /var/www/common/server-health-check.py || true
        return 1
    fi
    echo "[$DBNAME] Novi backup kreiran: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

    # 3. Upload na Google Drive
    if "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^gdrive:"; then
        echo "[$DBNAME] Upload na Google Drive..."
        if [ "$DBNAME" == "synora" ]; then
            "$RCLONE_BIN" copyto "$BACKUP_FILE" "$GDRIVE_REMOTE/synora/$(basename "$BACKUP_FILE")" --log-level NOTICE
        else
            "$RCLONE_BIN" copyto "$BACKUP_FILE" "$GDRIVE_REMOTE/$(basename "$BACKUP_FILE")" --log-level NOTICE
        fi
        echo "[$DBNAME] Upload na Google Drive uspjesno zavrsen."
        
        # 4. Spasi novo stanje promjena tek nakon uspjesnog uploada
        echo "$CURRENT_STATE" > "$STATE_FILE"

        # 5. Rotacija: obriši samo prethodni automatski backup
        local AUTO_BACKUPS=($(ls -t "$BACKUP_DIR"/"$DBNAME"-AB-*.sql* 2>/dev/null || true))
        if [ ${#AUTO_BACKUPS[@]} -ge 2 ]; then
            local PREV_BACKUP="${AUTO_BACKUPS[1]}"
            if [ -f "$PREV_BACKUP" ] && [ "$PREV_BACKUP" != "$BACKUP_FILE" ]; then
                echo "[$DBNAME] Brisanje prethodnog lokalnog backupa: $PREV_BACKUP"
                rm -f "$PREV_BACKUP"
            fi
        fi
    fi
}

# Pokreni provjeru i backup za obje baze
backup_database "Scout2DB"
backup_database "synora"

# Očisti privremeni Docker build cache
echo "=== Cleaning temporary Docker build cache ==="
/usr/bin/docker builder prune -f --reserved-space 1GB 2>/dev/null || true

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Backup proces zavrsen uspjesno ==="
