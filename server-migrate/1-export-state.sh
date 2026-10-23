#!/bin/bash
# 100% Read-Only State Export from Production Server
# Streams all non-Git configs, secrets, certs, and DB backups over SSH into ./bundle/ without writing anything on the remote server.
# Usage: ./1-export-state.sh [user@host]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="${SCRIPT_DIR}/bundle"
TARGET="${1:-seidme@159.65.123.140}"

mkdir -p "${BUNDLE_DIR}"/{env,ssh,rclone,cron,db_backups}

echo "=== [1/6] Exporting .env files from ${TARGET} ==="
ssh "$TARGET" "cat /var/www/synora/.env" > "${BUNDLE_DIR}/env/synora.env"
ssh "$TARGET" "cat /var/www/scout/eMo.API/.env" > "${BUNDLE_DIR}/env/scout_emo_api.env"
ssh "$TARGET" "cat /var/www/scout/eMo.API/.env.production" > "${BUNDLE_DIR}/env/scout_emo_api.env.production"

echo "=== [2/6] Exporting SSH keys, gitconfig, and rclone.conf ==="
ssh "$TARGET" "tar -czf - -C /home/seidme .ssh .gitconfig" > "${BUNDLE_DIR}/ssh/home_ssh_and_gitconfig.tar.gz"
ssh "$TARGET" "cat /home/seidme/.config/rclone/rclone.conf" > "${BUNDLE_DIR}/rclone/rclone.conf"
chmod 600 "${BUNDLE_DIR}/rclone/rclone.conf" "${BUNDLE_DIR}/ssh/home_ssh_and_gitconfig.tar.gz"

echo "=== [3/6] Exporting crontab and cloudflared tunnel command ==="
ssh "$TARGET" "crontab -l" > "${BUNDLE_DIR}/cron/seidme.crontab"
ssh "$TARGET" "docker inspect cloudflared --format '{{join .Config.Cmd \" \"}}'" > "${BUNDLE_DIR}/cloudflared_cmd.txt"

echo "=== [4/6] Streaming Let's Encrypt certificates (/var/www/proxy/certbot) ==="
# Uses read-only alpine container mount because certbot private keys are owned by root:root
ssh "$TARGET" "sudo -n /usr/bin/docker run --rm -v /var/www/proxy/certbot:/certbot:ro alpine tar -czf - -C /certbot ." > "${BUNDLE_DIR}/certbot.tar.gz"
chmod 600 "${BUNDLE_DIR}/certbot.tar.gz"

echo "=== [5/6] Streaming static site (/var/www/codeeve), /var/www/common/olx, synora data & common backup scripts ==="
ssh "$TARGET" "tar -czf - -C /var/www codeeve" > "${BUNDLE_DIR}/codeeve.tar.gz"
ssh "$TARGET" "tar -czf - -C /var/www/common olx" > "${BUNDLE_DIR}/olx.tar.gz"
ssh "$TARGET" "tar -czf - -C /var/www/synora backend/data 2>/dev/null || true" > "${BUNDLE_DIR}/synora_data.tar.gz"
ssh "$TARGET" "tar -czf - -C /var/www/common nightly-backup-and-cleanup.sh monthly-raw-backup.sh 2>/dev/null || true" > "${BUNDLE_DIR}/common_scripts.tar.gz"

echo "=== [6/6] Downloading latest PostgreSQL backups (/var/www/scout/db/backups) ==="
rsync -avz --exclude='synora-manual-backup-*' "${TARGET}:/var/www/scout/db/backups/" "${BUNDLE_DIR}/db_backups/"
echo "Streaming live up-to-the-second Scout2DB public schema dump..."
ssh "$TARGET" "docker exec postgresdb pg_dump -U postgres --schema=public Scout2DB | gzip" > "${BUNDLE_DIR}/db_backups/Scout2DB-AB-$(date +%F)-live.sql.gz"

echo ""
echo "Export complete! All stateful assets saved to: ${BUNDLE_DIR}"
ls -lh "${BUNDLE_DIR}" "${BUNDLE_DIR}/db_backups"
