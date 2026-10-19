#!/bin/bash
set -e

BACKUP_DIR="/var/www/scout/db/backups"
DATE=$(date +%F)
RCLONE_BIN="/home/seidme/.local/bin/rclone"
GDRIVE_REMOTE="gdrive:"
PG_PASS="7Hjdf4l#-cqYeD89@-wapKe34=-er5Tfv3!"
FORCE=false
if [ "$1" == "--force" ]; then
    FORCE=true
fi

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Starting automated database backup check ==="

backup_database() {
    local DBNAME="$1"
    local SCHEMA="$2"
    local BACKUP_FILE="${BACKUP_DIR}/${DBNAME}-AB-${DATE}.sql.gz"
    local STATE_FILE="${BACKUP_DIR}/.${DBNAME}.last_state"
    local DUMP_ARGS=()

    if [ -n "$SCHEMA" ]; then
        DUMP_ARGS+=(--schema="$SCHEMA")
        # Dobavi stanje promjena (inserti, updejti, deleti) za specifičnu shemu
        local CURRENT_STATE=$(/usr/bin/docker exec -e PGPASSWORD="$PG_PASS" postgresdb psql -U postgres -d "$DBNAME" -Atc \
            "SELECT COALESCE(sum(n_tup_ins), 0) || ':' || COALESCE(sum(n_tup_upd), 0) || ':' || COALESCE(sum(n_tup_del), 0) FROM pg_stat_user_tables WHERE schemaname = '$SCHEMA';" 2>/dev/null || echo "")
    else
        # Isključi raw shemu iz standardnog nightly backupa
        DUMP_ARGS+=(--exclude-schema=raw)
        # Dobavi stanje promjena za sve sheme osim raw
        local CURRENT_STATE=$(/usr/bin/docker exec -e PGPASSWORD="$PG_PASS" postgresdb psql -U postgres -d "$DBNAME" -Atc \
            "SELECT COALESCE(sum(n_tup_ins), 0) || ':' || COALESCE(sum(n_tup_upd), 0) || ':' || COALESCE(sum(n_tup_del), 0) FROM pg_stat_user_tables WHERE schemaname != 'raw';" 2>/dev/null || echo "")
    fi

    if [ "$FORCE" = false ]; then
        if [ -z "$CURRENT_STATE" ]; then
            echo "WARNING: Could not fetch database stats for '$DBNAME' (schema: ${SCHEMA:-all except raw}). Proceeding with fallback backup."
        elif [ -f "$STATE_FILE" ] && [ "$CURRENT_STATE" == "$(cat "$STATE_FILE" 2>/dev/null)" ]; then
            echo "[$DBNAME] Nema novih izmjena u bazi od zadnjeg backupa ($CURRENT_STATE). Preskacem dump i upload."
            return 0
        fi
    else
        echo "[$DBNAME] Force flag uključen. Pokrećem backup bez obzira na stanje..."
    fi

    echo "[$DBNAME] Detektovane nove izmjene (ili prvi run / force). Pokrecem backup (schema: ${SCHEMA:-all except raw})..."
    
    # 1. Kreiraj kompresovani backup
    /usr/bin/docker exec -e PGPASSWORD="$PG_PASS" postgresdb pg_dump -U postgres "${DUMP_ARGS[@]}" "$DBNAME" 2>/dev/null | gzip > "$BACKUP_FILE"
    
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

# Pokreni provjeru i backup za obje baze (Scout2DB cilja samo public shemu)
backup_database "Scout2DB" "public"
backup_database "synora"

# Očisti privremeni Docker build cache
echo "=== Cleaning temporary Docker build cache ==="
/usr/bin/docker builder prune -f --reserved-space 1GB 2>/dev/null || true

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Backup proces zavrsen uspjesno ==="
