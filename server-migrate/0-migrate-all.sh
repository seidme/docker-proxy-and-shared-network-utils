#!/bin/bash
# Turnkey End-to-End Server Migration Orchestrator (Run from your Mac)
# Pulls live state from the old DigitalOcean server, provisions the new Ubuntu 24.04 server,
# restores all repos/databases/certs/containers, and runs a read-only verification audit.
#
# Usage:
#   ./0-migrate-all.sh <NEW_SERVER_IP> [OLD_SSH_TARGET]
# Example:
#   ./0-migrate-all.sh 203.0.113.50
#   ./0-migrate-all.sh 203.0.113.50 seidme@159.65.123.140

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <NEW_SERVER_IP> [OLD_SSH_TARGET]"
  echo "Example: $0 203.0.113.50 seidme@159.65.123.140"
  exit 1
fi

NEW_IP="$1"
OLD_TARGET="${2:-seidme@159.65.123.140}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=================================================================="
echo " Starting Turnkey Server Migration"
echo " Source Server : ${OLD_TARGET}"
echo " Target Server : ${NEW_IP}"
echo "=================================================================="

echo ""
echo ">>> [Step 1/5] Exporting non-Git state & DB backups from ${OLD_TARGET}..."
bash "${SCRIPT_DIR}/1-export-state.sh" "${OLD_TARGET}" "${SCRIPT_DIR}/bundle"

echo ""
echo ">>> [Step 2/5] Uploading migration kit & bundle to root@${NEW_IP}:/root/server-migrate..."
ssh -o StrictHostKeyChecking=accept-new "root@${NEW_IP}" "mkdir -p /root/server-migrate"
scp -r "${SCRIPT_DIR}/." "root@${NEW_IP}:/root/server-migrate/"

echo ""
echo ">>> [Step 3/5] Provisioning OS, 4GB swap, journald cap, Docker & rclone on ${NEW_IP}..."
ssh "root@${NEW_IP}" "bash /root/server-migrate/2-provision-new-server.sh"

echo ""
echo ">>> [Step 4/5] Restoring SSH keys, repos, .env files, certs, Postgres DBs & Docker stacks..."
ssh -o StrictHostKeyChecking=accept-new "seidme@${NEW_IP}" "bash /var/www/server-migrate/3-restore-and-start.sh /var/www/server-migrate/bundle"

echo ""
echo ">>> [Step 5/5] Running read-only verification audit against seidme@${NEW_IP}..."
bash "${SCRIPT_DIR}/audit-server.sh" "seidme@${NEW_IP}"

cat <<EOF

==================================================================
 Server Migration Complete on ${NEW_IP}!
 Complete the external cutover checklist in README.md:
   1. Smoke-test locally via /etc/hosts -> ${NEW_IP}
   2. Stop cloudflared on old server: ssh ${OLD_TARGET} "docker stop cloudflared"
   3. Update Cloudflare DNS 'A' records for codeeve.com & subdomains -> ${NEW_IP}
   4. Update GitHub Actions server IP secrets across repos -> ${NEW_IP}
   5. Clean up /root/server-migrate and /var/www/server-migrate/bundle on ${NEW_IP}
==================================================================
EOF
