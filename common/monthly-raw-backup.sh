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

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Starting monthly raw schema backup check ==="

backup_raw_schema() {
    local DBNAME="$1"
    local SCHEMA="raw"
    local BACKUP_FILE="${BACKUP_DIR}/${DBNAME}-raw-MB-${DATE}.sql.gz"
    local STATE_FILE="${BACKUP_DIR}/.${DBNAME}.${SCHEMA}.last_state"

    # Provjeri da li postoji raw shema u bazi
    local SCHEMA_EXISTS=$(/usr/bin/docker exec -e PGPASSWORD="$PG_PASS" postgresdb psql -U postgres -d "$DBNAME" -Atc \
        "SELECT 1 FROM information_schema.schemata WHERE schema_name = '$SCHEMA';" 2>/dev/null || echo "")

    if [ "$SCHEMA_EXISTS" != "1" ]; then
        echo "[$DBNAME] Shema '$SCHEMA' ne postoji u bazi. Preskacem."
        return 0
    fi

    # Dobavi stanje promjena za raw shemu (inserti, updejti, deleti)
    local CURRENT_STATE=$(/usr/bin/docker exec -e PGPASSWORD="$PG_PASS" postgresdb psql -U postgres -d "$DBNAME" -Atc \
        "SELECT COALESCE(sum(n_tup_ins), 0) || ':' || COALESCE(sum(n_tup_upd), 0) || ':' || COALESCE(sum(n_tup_del), 0) FROM pg_stat_user_tables WHERE schemaname = '$SCHEMA';" 2>/dev/null || echo "")

    if [ "$FORCE" = false ]; then
        if [ -z "$CURRENT_STATE" ]; then
            echo "WARNING: Could not fetch stats for '$DBNAME.$SCHEMA'. Proceeding with fallback backup."
        elif [ -f "$STATE_FILE" ] && [ "$CURRENT_STATE" == "$(cat "$STATE_FILE" 2>/dev/null)" ]; then
            echo "[$DBNAME.$SCHEMA] Nema novih izmjena u raw shemi od zadnjeg backupa ($CURRENT_STATE). Preskacem dump i upload."
            return 0
        fi
    else
        echo "[$DBNAME.$SCHEMA] Force flag uključen. Pokrećem backup bez obzira na stanje..."
    fi

    echo "[$DBNAME.$SCHEMA] Detektovane promjene (ili prvi run / force). Pokrecem backup raw sheme..."

    # 1. Kreiraj kompresovani backup samo za raw shemu
    /usr/bin/docker exec -e PGPASSWORD="$PG_PASS" postgresdb pg_dump -U postgres --schema="$SCHEMA" "$DBNAME" 2>/dev/null | gzip > "$BACKUP_FILE"

    # 2. Provjera veličine (minimalno 500KB za raw shemu sa podacima)
    local FILE_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo 0)
    if [ ! -s "$BACKUP_FILE" ] || [ "$FILE_SIZE" -lt 512000 ]; then
        echo "ERROR: Raw backup file for '$DBNAME.$SCHEMA' is missing or smaller than 500KB!"
        /usr/bin/python3 /var/www/common/server-health-check.py || true
        return 1
    fi
    echo "[$DBNAME.$SCHEMA] Novi raw backup kreiran: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

    # 3. Upload na Google Drive (podfolder raw/)
    if "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^gdrive:"; then
        echo "[$DBNAME.$SCHEMA] Upload na Google Drive (raw/)..."
        "$RCLONE_BIN" copyto "$BACKUP_FILE" "$GDRIVE_REMOTE/raw/$(basename "$BACKUP_FILE")" --log-level NOTICE
        echo "[$DBNAME.$SCHEMA] Upload na Google Drive uspjesno zavrsen."

        # 4. Spasi novo stanje promjena tek nakon uspjesnog uploada
        echo "$CURRENT_STATE" > "$STATE_FILE"

        # 5. Rotacija: zadrži zadnja 3 lokalna mjesečna raw backupa
        local RAW_BACKUPS=($(ls -t "$BACKUP_DIR"/"$DBNAME"-raw-MB-*.sql* 2>/dev/null || true))
        if [ ${#RAW_BACKUPS[@]} -gt 3 ]; then
            for ((i=3; i<${#RAW_BACKUPS[@]}; i++)); do
                local OLD_BACKUP="${RAW_BACKUPS[$i]}"
                if [ -f "$OLD_BACKUP" ]; then
                    echo "[$DBNAME.$SCHEMA] Brisanje starog lokalnog raw backupa: $OLD_BACKUP"
                    rm -f "$OLD_BACKUP"
                fi
            done
        fi
    fi
}

# Pokreni mjesečni backup raw sheme za Scout2DB
backup_raw_schema "Scout2DB"

echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Monthly raw schema backup proces zavrsen uspjesno ==="
