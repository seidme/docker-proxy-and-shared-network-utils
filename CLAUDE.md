# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides infrastructure for running multiple Docker-based applications behind a shared nginx reverse proxy. It consists of:

1. **Proxy Layer** (`proxy/`) - Nginx reverse proxy with SSL/TLS termination using Let's Encrypt
2. **Common Utilities** (`common/`) - Shared scripts for orchestrating multi-stack Docker deployments

The key architectural pattern is a shared Docker network (`public-network`) that allows the proxy to route traffic to backend services by container name.

## Architecture

### Network Topology

All services connect to an external Docker network called `public-network`. The proxy must be started first to create this network, then other application stacks join it.

**Service Flow:**
```
Internet → Nginx (ports 80/443) → Docker network (public-network) → Backend containers
```

The nginx configuration in `proxy/nginx/nginx.conf` proxies to backend services using internal container names:
- `scout.codeeve.com` → `http://piker-api:80`
- `flxng.codeeve.com` → `http://flxng-app:80`
- `codeeve.com` → static files from `/var/www/codeeve/html`

### SSL/TLS Configuration

Let's Encrypt certificates are managed via the `certbot` container. Certificates and ACME challenge files are shared between nginx and certbot via volume mounts:
- `./certbot/etc:/etc/letsencrypt` - Certificate storage
- `./certbot/www:/var/www/certbot` - ACME challenge directory

Nginx handles the `.well-known/acme-challenge/` location for domain validation on port 80, then redirects all other HTTP traffic to HTTPS.

### Proxy Timeouts

Backend proxies use extended timeouts (10 minutes) to handle long-running operations:
```
proxy_connect_timeout 600s;
proxy_send_timeout    600s;
proxy_read_timeout    600s;
```

## Key Commands

### Starting the Stack

The orchestration script must start services in order (proxy first, then apps):

```bash
cd common/
sh docker-start-apps.sh
```

This script:
1. Stops all running stacks
2. Starts proxy (creates `public-network`)
3. Starts scout application with build
4. Starts flxng application with build

### Manual Stack Management

Start proxy only:
```bash
cd proxy/
docker compose up -d
```

Stop all services:
```bash
cd /path/to/proxy && docker compose down
cd /path/to/scout && docker compose down
cd /path/to/flxng && docker compose down
```

Restart nginx to reload configuration:
```bash
docker exec nginx-proxy nginx -s reload
```

## Deployment

The repository uses GitHub Actions for automated deployment (`deploy.yml`). On push to `main` or `master`:
1. SSH into remote server
2. Pull latest changes from GitHub
3. Run `docker-start-apps.sh` to restart all stacks

Required secrets: `SSH_HOST`, `SSH_USERNAME`, `SSH_KEY`

## Expected Directory Structure on Server

The deployment script expects this layout on the production server:
```
/var/www/
├── proxy/          # This repository's proxy/ directory
├── scout/          # Scout application (separate repo)
├── flxng/          # Flxng application (separate repo)
└── common/         # This repository's common/ directory
```

## Configuration Notes

### Adding a New Backend Service

To proxy a new subdomain:

1. Add SSL certificates to `proxy/certbot/etc/live/`
2. Add server block in `proxy/nginx/nginx.conf`:
   ```nginx
   server {
       listen 443 ssl;
       server_name newapp.codeeve.com;
       ssl_certificate /etc/letsencrypt/live/newapp.codeeve.com/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/newapp.codeeve.com/privkey.pem;

       location / {
           proxy_pass http://newapp-container:80;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
       }
   }
   ```
3. Add HTTP server_name to the redirect block (line 22)
4. Ensure the backend container joins `public-network` in its docker-compose.yml
5. Update `common/docker-start-apps.sh` to include the new stack

### Network Security

The nginx config includes a default server block that returns 444 (connection closed) for requests without a matching `server_name`. This prevents direct IP access and undefined host header attacks.
