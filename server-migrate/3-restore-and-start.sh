#!/bin/bash
# Restore State, Clone Repositories, Restore Databases & Start All Docker Stacks
# Run as 'seidme' on the new server after running 2-provision-new-server.sh:
#   bash 3-restore-and-start.sh [/path/to/bundle]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="${1:-${SCRIPT_DIR}/bundle}"

if [ ! -d "${BUNDLE_DIR}" ]; then
  echo "Error: Bundle directory not found at ${BUNDLE_DIR}"
  echo "Run 1-export-state.sh first and copy the bundle directory to the new server."
  exit 1
fi

echo "=== [1/7] Restoring SSH Keys, .gitconfig, and rclone.conf ==="
tar -xzf "${BUNDLE_DIR}/ssh/home_ssh_and_gitconfig.tar.gz" -C "${HOME}"
chmod 700 "${HOME}/.ssh"
chmod 600 "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/github_actions_key" "${HOME}/.ssh/authorized_keys" 2>/dev/null || true

mkdir -p "${HOME}/.config/rclone"
cp "${BUNDLE_DIR}/rclone/rclone.conf" "${HOME}/.config/rclone/rclone.conf"
chmod 600 "${HOME}/.config/rclone/rclone.conf"

echo "=== [2/7] Cloning Repositories into /var/www ==="
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
if [ ! -d "/var/www/.git" ]; then
  TMP_WWW="$(mktemp -d)"
  git clone -b master git@github.com:seidme/docker-proxy-and-shared-network-utils.git "${TMP_WWW}"
  rsync -a --exclude='server-migrate' "${TMP_WWW}/" /var/www/
  rm -rf "${TMP_WWW}"
fi

clone_or_update() {
  local repo_url="$1"
  local target_dir="$2"
  local branch="$3"
  if [ ! -d "${target_dir}/.git" ]; then
    git clone -b "${branch}" "${repo_url}" "${target_dir}"
  else
    git -C "${target_dir}" fetch origin
    git -C "${target_dir}" checkout "${branch}"
    git -C "${target_dir}" pull origin "${branch}"
  fi
}

clone_or_update "git@github.com:seidme/scout.git" "/var/www/scout" "master"
clone_or_update "git@github.com:seidme/synora.git" "/var/www/synora" "main"
clone_or_update "git@github.com:seidme/flxng.git" "/var/www/flxng" "v1"
clone_or_update "git@github.com:seidme/video-downloader.git" "/var/www/video-downloader" "main"

echo "=== [3/7] Restoring .env Files, Static Site, olx & Let's Encrypt Certs ==="
cp "${BUNDLE_DIR}/env/synora.env" /var/www/synora/.env
cp "${BUNDLE_DIR}/env/scout_emo_api.env" /var/www/scout/eMo.API/.env
cp "${BUNDLE_DIR}/env/scout_emo_api.env.production" /var/www/scout/eMo.API/.env.production

tar -xzf "${BUNDLE_DIR}/codeeve.tar.gz" -C /var/www
tar -xzf "${BUNDLE_DIR}/olx.tar.gz" -C /var/www/common
if [ -s "${BUNDLE_DIR}/synora_data.tar.gz" ]; then
  tar -xzf "${BUNDLE_DIR}/synora_data.tar.gz" -C /var/www/synora
fi
if [ -s "${BUNDLE_DIR}/common_scripts.tar.gz" ]; then
  tar -xzf "${BUNDLE_DIR}/common_scripts.tar.gz" -C /var/www/common
fi

mkdir -p /var/www/proxy/certbot
sudo /usr/bin/docker run --rm \
  -v /var/www/proxy/certbot:/certbot \
  -v "${BUNDLE_DIR}/certbot.tar.gz:/certbot.tar.gz:ro" \
  alpine tar -xzf /certbot.tar.gz -C /certbot

echo "=== [4/7] Restoring Database Backups Directory & Starting Postgres ==="
mkdir -p /var/www/scout/db/backups
if [ -d "${BUNDLE_DIR}/db_backups" ]; then
  cp -a "${BUNDLE_DIR}/db_backups/." /var/www/scout/db/backups/
fi

RCLONE_BIN="${HOME}/.local/bin/rclone"
if [ -x "${RCLONE_BIN}" ] && "${RCLONE_BIN}" listremotes 2>/dev/null | grep -q "^gdrive:"; then
  if ! ls /var/www/scout/db/backups/Scout2DB-AB-*.sql.gz >/dev/null 2>&1; then
    LATEST_GDRIVE_SCOUT="$("${RCLONE_BIN}" lsf gdrive: --include "Scout2DB-AB-*.sql.gz" | sort | tail -n 1)"
    [ -n "${LATEST_GDRIVE_SCOUT}" ] && "${RCLONE_BIN}" copyto "gdrive:${LATEST_GDRIVE_SCOUT}" "/var/www/scout/db/backups/${LATEST_GDRIVE_SCOUT}"
  fi
  if ! ls /var/www/scout/db/backups/Scout2DB-raw-MB-*.sql.gz >/dev/null 2>&1; then
    LATEST_GDRIVE_RAW="$("${RCLONE_BIN}" lsf gdrive:raw/ --include "Scout2DB-raw-MB-*.sql.gz" | sort | tail -n 1)"
    [ -n "${LATEST_GDRIVE_RAW}" ] && "${RCLONE_BIN}" copyto "gdrive:raw/${LATEST_GDRIVE_RAW}" "/var/www/scout/db/backups/${LATEST_GDRIVE_RAW}"
  fi
  if ! ls /var/www/scout/db/backups/synora-AB-*.sql.gz >/dev/null 2>&1; then
    LATEST_GDRIVE_SYNORA="$("${RCLONE_BIN}" lsf gdrive:synora/ --include "synora-AB-*.sql.gz" | sort | tail -n 1)"
    [ -n "${LATEST_GDRIVE_SYNORA}" ] && "${RCLONE_BIN}" copyto "gdrive:synora/${LATEST_GDRIVE_SYNORA}" "/var/www/scout/db/backups/${LATEST_GDRIVE_SYNORA}"
  fi
fi

docker network inspect public-network >/dev/null 2>&1 || docker network create public-network

cd /var/www/scout
docker compose up -d postgresdb

echo "Waiting for postgresdb to become healthy..."
until docker exec postgresdb pg_isready -U postgres >/dev/null 2>&1; do
  sleep 2
done

echo "=== [5/7] Creating & Restoring PostgreSQL Databases ==="
for db in Scout2DB Scout2DBPlayground synora; do
  docker exec postgresdb psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1 || \
    docker exec postgresdb psql -U postgres -c "CREATE DATABASE \"${db}\";"
done

LATEST_SCOUT_PUB="$(ls -t /var/www/scout/db/backups/Scout2DB-AB-*.sql.gz 2>/dev/null | head -n 1 || true)"
LATEST_SCOUT_RAW="$(ls -t /var/www/scout/db/backups/Scout2DB-raw-MB-*.sql.gz 2>/dev/null | head -n 1 || true)"
LATEST_SYNORA="$(ls -t /var/www/scout/db/backups/synora-AB-*.sql.gz 2>/dev/null | head -n 1 || true)"
LATEST_PLAYGROUND="$(ls -t /var/www/scout/db/backups/Scout2DBPlayground-*.sql 2>/dev/null | head -n 1 || true)"

if [ -n "${LATEST_SCOUT_PUB}" ]; then
  echo "Restoring Scout2DB public schema from ${LATEST_SCOUT_PUB}..."
  gunzip -c "${LATEST_SCOUT_PUB}" | docker exec -i postgresdb psql -U postgres -d Scout2DB >/dev/null
fi
if [ -n "${LATEST_SCOUT_RAW}" ]; then
  echo "Restoring Scout2DB raw schema from ${LATEST_SCOUT_RAW}..."
  gunzip -c "${LATEST_SCOUT_RAW}" | docker exec -i postgresdb psql -U postgres -d Scout2DB >/dev/null
fi
if [ -n "${LATEST_SYNORA}" ]; then
  echo "Restoring synora database from ${LATEST_SYNORA}..."
  gunzip -c "${LATEST_SYNORA}" | docker exec -i postgresdb psql -U postgres -d synora >/dev/null
fi
if [ -n "${LATEST_PLAYGROUND}" ]; then
  echo "Restoring Scout2DBPlayground from ${LATEST_PLAYGROUND}..."
  docker exec -i postgresdb psql -U postgres -d Scout2DBPlayground < "${LATEST_PLAYGROUND}" >/dev/null
fi

echo "=== [6/7] Starting All Docker Compose Stacks & Cloudflared ==="
git -C /var/www/scout checkout -- Piker.Web/Dockerfile 2>/dev/null || true
sed -i 's/npm install$/npm install --legacy-peer-deps/' /var/www/scout/Piker.Web/Dockerfile 2>/dev/null || true
git -C /var/www/synora checkout -- frontend/Dockerfile backend/Dockerfile 2>/dev/null || true
sed -i 's/^RUN npm install$/RUN rm -f package-lock.json \&\& npm install --legacy-peer-deps/' /var/www/synora/frontend/Dockerfile 2>/dev/null || true
sed -i 's/^RUN npm install --legacy-peer-deps$/RUN rm -f package-lock.json \&\& npm install --legacy-peer-deps/' /var/www/synora/backend/Dockerfile 2>/dev/null || true
cd /var/www/proxy && docker compose up -d
cd /var/www/scout && docker compose up -d --build
cd /var/www/synora && docker compose up -d --build
cd /var/www/flxng && docker compose up -d --build
cd /var/www/video-downloader && docker compose up -d --build

if [ -f "${BUNDLE_DIR}/cloudflared_cmd.txt" ]; then
  CF_CMD="$(cat "${BUNDLE_DIR}/cloudflared_cmd.txt")"
  if ! docker ps -a --format '{{.Names}}' | grep -qx "cloudflared"; then
    # shellcheck disable=SC2086
    docker run -d --name cloudflared --restart unless-stopped cloudflare/cloudflared:latest ${CF_CMD}
  fi
fi

echo "=== [7/7] Installing Crontab & Pruning Build Cache ==="
if [ -f "${BUNDLE_DIR}/cron/seidme.crontab" ]; then
  crontab "${BUNDLE_DIR}/cron/seidme.crontab"
fi
docker builder prune -af >/dev/null 2>&1 || true
docker image prune -f >/dev/null 2>&1 || true

echo ""
echo "Migration & restoration complete! Running containers:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
df -h /
