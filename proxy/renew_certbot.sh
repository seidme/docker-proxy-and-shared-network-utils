#!/bin/bash
# set -e

# CONFIG — change if your folder differs
CERTBOT_ETC="./certbot/etc"

echo "=== Stopping nginx-proxy ==="
/usr/bin/docker stop nginx-proxy

echo "=== Running certbot renew on port 80 (standalone mode) ==="
/usr/bin/docker run --rm \
  -p 80:80 \
  -v "$(pwd)/certbot/etc:/etc/letsencrypt" \
  certbot/certbot renew

echo "=== Starting nginx-proxy ==="
/usr/bin/docker start nginx-proxy

echo "=== Renewal complete ==="
