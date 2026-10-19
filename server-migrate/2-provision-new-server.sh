#!/bin/bash
# Bootstrap & Provisioning Script for a Fresh Ubuntu 24.04 LTS Droplet
# Mirrors all OS tuning, swap, packages, Docker CE, rclone, and user permissions from 159.65.123.140.
# Run as root (or with sudo) on the new server:
#   sudo bash 2-provision-new-server.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root (sudo bash 2-provision-new-server.sh)"
  exit 1
fi

TARGET_USER="seidme"

echo "=== [1/6] Setting Timezone to Etc/UTC ==="
timedatectl set-timezone Etc/UTC

echo "=== [2/6] Configuring 4GB /swapfile ==="
if ! swapon --show | grep -q "/swapfile"; then
  if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
fi
if ! grep -q "^/swapfile" /etc/fstab; then
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

echo "=== [3/6] Capping systemd-journald logs at 200M ==="
if grep -q "^#*SystemMaxUse=" /etc/systemd/journald.conf; then
  sed -i 's/^#*SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
else
  echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
fi
systemctl restart systemd-journald

echo "=== [4/6] Installing APT Prerequisites & Official Docker CE ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates apt-utils apt-transport-https gnupg2 curl git ufw rsync python3

install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "=== [5/6] Configuring User '${TARGET_USER}' & Sudoers ==="
if ! id "${TARGET_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,users,docker "${TARGET_USER}"
else
  usermod -aG sudo,users,docker "${TARGET_USER}"
fi

cat <<EOF > /etc/sudoers.d/90-seidme-docker
${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/local/bin/docker
EOF
chmod 0440 /etc/sudoers.d/90-seidme-docker

mkdir -p /var/www
chown -R "${TARGET_USER}:${TARGET_USER}" /var/www

echo "=== [6/6] Installing Standalone rclone Binary for '${TARGET_USER}' ==="
sudo -u "${TARGET_USER}" mkdir -p "/home/${TARGET_USER}/.local/bin" "/home/${TARGET_USER}/.config/rclone"
if [ ! -x "/home/${TARGET_USER}/.local/bin/rclone" ]; then
  TMP_RCLONE="$(mktemp -d)"
  curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o "${TMP_RCLONE}/rclone.zip"
  python3 -m zipfile -e "${TMP_RCLONE}/rclone.zip" "${TMP_RCLONE}/"
  cp "${TMP_RCLONE}"/rclone-*-linux-amd64/rclone "/home/${TARGET_USER}/.local/bin/rclone"
  chmod 775 "/home/${TARGET_USER}/.local/bin/rclone"
  chown "${TARGET_USER}:${TARGET_USER}" "/home/${TARGET_USER}/.local/bin/rclone"
  rm -rf "${TMP_RCLONE}"
fi

echo ""
echo "Provisioning complete!"
docker --version
docker compose version
"/home/${TARGET_USER}/.local/bin/rclone" version | head -n 1
swapon --show
