#!/bin/bash
# 100% Read-Only Server Audit Script
# Runs over SSH (or locally if no host argument is given) without writing or modifying anything on the server.
# Usage: ./audit-server.sh [user@host]

set -euo pipefail

TARGET="${1:-seidme@159.65.123.140}"

echo "Running 100% read-only audit against ${TARGET}..."

ssh -o BatchMode=yes "$TARGET" '
echo "================================================================="
echo "1. OS, KERNEL, HARDWARE & SWAP"
echo "================================================================="
grep -E "^(NAME|VERSION)=" /etc/os-release
uname -a
lscpu | grep -E "Model name|CPU\(s\):"
free -h
swapon --show
df -h -x overlay -x tmpfs
echo "--- /etc/fstab ---"
cat /etc/fstab

echo ""
echo "================================================================="
echo "2. MODIFIED PACKAGED FILES ACROSS ENTIRE FILESYSTEM (dpkg -V)"
echo "================================================================="
dpkg -V 2>/dev/null || true
echo "--- /etc/systemd/journald.conf non-comment lines ---"
grep -vE "^(#|$)" /etc/systemd/journald.conf || true

echo ""
echo "================================================================="
echo "3. APT SOURCES & MANUAL INSTALL HISTORY"
echo "================================================================="
ls -la /etc/apt/sources.list.d/ /etc/apt/keyrings/ 2>/dev/null
zgrep -h "Commandline:" /var/log/apt/history.log* 2>/dev/null | grep -v "unattended-upgrade" | grep -v "droplet-agent" || true

echo ""
echo "================================================================="
echo "4. STANDALONE BINARIES & USER CONFIGS (/usr/local, /opt, ~/.local)"
echo "================================================================="
ls -la /usr/local/bin /opt /home/seidme/.local/bin /home/seidme/.config 2>/dev/null
if [ -x /home/seidme/.local/bin/rclone ]; then
  /home/seidme/.local/bin/rclone --version | head -n 1
  echo "Rclone remotes:"
  /home/seidme/.local/bin/rclone listremotes
fi

echo ""
echo "================================================================="
echo "5. CRONTABS"
echo "================================================================="
crontab -l 2>/dev/null || echo "No user crontab"

echo ""
echo "================================================================="
echo "6. /var/www REPOSITORIES, BRANCHES & UNTRACKED FILES"
echo "================================================================="
ls -la /var/www
for d in /var/www /var/www/scout /var/www/synora /var/www/flxng /var/www/video-downloader; do
  if [ -d "$d/.git" ]; then
    echo "--- Repo: $d (branch: $(git -C "$d" branch --show-current)) ---"
    git -C "$d" remote -v | head -n 1
    git -C "$d" status --ignored -s
  fi
done

echo ""
echo "================================================================="
echo "7. DOCKER CONTAINERS, VOLUMES, NETWORKS & POSTGRES DATABASES"
echo "================================================================="
docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
echo "--- Volumes ---"
docker volume ls --format "{{.Name}}" | grep -vE "^[0-9a-f]{64}$"
echo "--- Networks ---"
docker network ls
echo "--- Postgres Databases ---"
docker exec postgresdb psql -U postgres -c "\l" 2>/dev/null || true
'
