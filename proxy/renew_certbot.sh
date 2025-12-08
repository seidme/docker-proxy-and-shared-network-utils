#!/bin/bash
# set -e

# CONFIG — change if your folder differs
CERTBOT_ETC="./certbot/etc"

echo "=== Stopping nginx-proxy ==="
docker stop nginx-proxy

echo "=== Running certbot renew on port 80 (standalone mode) ==="
docker run --rm -it \
  -p 80:80 \
  -v "$(pwd)/certbot/etc:/etc/letsencrypt" \
  certbot/certbot renew

echo "=== Starting nginx-proxy ==="
docker start nginx-proxy

echo "=== Renewal complete ==="
