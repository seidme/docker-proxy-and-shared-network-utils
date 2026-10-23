# Server Audit & Turnkey Migration Kit

Complete audit of the current DigitalOcean production droplet (`159.65.123.140`, `ubuntu-24-04`) compared against a clean Ubuntu 24.04 LTS cloud image, along with automated scripts to export state and provision a mirror server from scratch.

---

## 1. Current Server Audit Summary (`159.65.123.140`)

### OS, Hardware & System Tuning
- **OS:** Ubuntu 24.04.3 LTS (Noble Numbat), Kernel `6.8.0-79-generic` (`x86_64`), Timezone `Etc/UTC`.
- **Hardware:** 1 vCPU (`DO-Premium-AMD`), 1 GB RAM (`961 MiB`), 25 GB SSD (`/dev/vda1`).
- **Swap (`4 GB`):** `/swapfile` (`4G`) mounted via `/etc/fstab` (`/swapfile none swap sw 0 0`). *(Clean droplets have 0 swap; critical on 1 GB RAM to prevent OOM during Docker builds and `pg_dump`.)*
- **Journald Log Cap (`/etc/systemd/journald.conf`):** `SystemMaxUse=200M` *(prevents `/var/log/journal` from filling the 25 GB disk)*.
- **Sudoers (`/etc/sudoers`):** User `seidme` (`uid=1000`, groups `sudo,users,docker`) has passwordless Docker privileges:
  ```text
  seidme ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/local/bin/docker
  ```

### Installed Packages & Standalone Tools
- **APT Repository Added:** Official Docker CE repository (`/etc/apt/keyrings/docker.asc` + `/etc/apt/sources.list.d/docker.list`).
- **APT Packages Installed Over Base Image:**
  - `ca-certificates`, `apt-utils`, `apt-transport-https`, `gnupg2`
  - `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- **Standalone Binary (Outside APT):**
  - `rclone` (`v1.75.0`) at `/home/seidme/.local/bin/rclone`
  - Config at `/home/seidme/.config/rclone/rclone.conf` (configured with `gdrive:` remote for Google Drive database backups).
- **Snap / `/usr/local/bin` / `/opt`:** No custom snap packages or `/usr/local/bin` scripts.

### User Configs & SSH Keys (`/home/seidme`)
- `.gitconfig`: `user.name = Seid M`, `user.email = mehmedovic.seid@gmail.com`
- `.ssh/id_ed25519` (+ `.pub`): Server SSH key used to pull private GitHub repos (`seidme/scout`, `seidme/synora`).
- `.ssh/github_actions_key` (+ `.pub`) & `.ssh/authorized_keys`: Used by GitHub Actions CI/CD deploy workflows.

### Cron Jobs (`crontab -l` for `seidme`)
```cron
# certs renewal - runs sunday morning at 6 am (7 am Sarajevo time)
0 6 * * 0 cd /var/www/proxy && ./renew_certbot.sh >> renew.log 2>&1

# Server Health Check - runs weekly on Monday at 08:00 UTC (09:00 Sarajevo time)
0 8 * * 1 /usr/bin/python3 /var/www/common/server-health-check.py >> /var/www/common/health.log 2>&1

# 02:00 UTC (03:00 Sarajevo time) - Automated backup & Google Drive sync
# [Disabled - Managed by GitHub Actions] 0 2 * * * /bin/bash /var/www/common/nightly-backup-and-cleanup.sh >> /var/www/common/backup.log 2>&1
```

### `/var/www` Directory & Repository Layout
`/var/www` itself is cloned from `git@github.com:seidme/docker-proxy-and-shared-network-utils.git` (`master`), with sub-repositories and untracked state inside it:

| Path | Source / Type | Branch | Untracked / Stateful Assets |
| :--- | :--- | :---: | :--- |
| `/var/www` | `seidme/docker-proxy-and-shared-network-utils` | `master` | `proxy/`, `common/` |
| `/var/www/proxy/certbot` | Let's Encrypt Volume | — | Certs for `codeeve.com`, `emo.codeeve.com`, `flxng.codeeve.com`, `piker.codeeve.com`, `scout.codeeve.com`, `synora.codeeve.com`, `video.codeeve.com` |
| `/var/www/codeeve/html` | Static Website | — | Static HTML/assets served for `codeeve.com` |
| `/var/www/scout` | `seidme/scout` | `master` | `eMo.API/.env`, `eMo.API/.env.production`, `db/backups/*.sql.gz` |
| `/var/www/synora` | `seidme/synora` | `main` | `.env`, `backend/data/*.sqlite` (read-only lakes), `backups/` |
| `/var/www/flxng` | `seidme/flxng` | `v1` | — |
| `/var/www/video-downloader` | `seidme/video-downloader` | `main` | `data/`, `downloads/` |
| `/var/www/common/olx` | Standalone Docker App | — | Local `Dockerfile`, `docker-compose.yml`, `configs/`, `data/` |

### Docker Networks, Volumes & Running Containers
- **External Network:** `public-network` (`bridge`)
- **Named Volumes:**
  - `scout_postgres_data`: Holds PostgreSQL 12 cluster with databases `Scout2DB`, `synora`, and `Scout2DBPlayground`.
  - `scout_piker_logs`: Piker API logs.
- **Containers:**
  - `nginx-proxy` (`nginx:1.25.3-alpine`, ports `80`, `443`)
  - `certbot` (`certbot/certbot`)
  - `postgresdb` (`postgres:12`, port `5432`)
  - `piker-api`, `piker-web`, `emo-api`, `browser-service` (`browserless/chrome:latest`, port `3000`)
  - `synora-api`, `synora-web`
  - `flxng-app`
  - `cloudflared` (`cloudflare/cloudflared:latest`, standalone container running `tunnel --no-autoupdate run --token <TOKEN>` with `--restart unless-stopped`)

---

## 2. Migration Scripts Overview

All scripts in this folder are designed to be safe and idempotent:

1. **`0-migrate-all.sh` (Turnkey One-Command Orchestrator):**
   Runs the entire end-to-end migration from your local Mac: exports state from `159.65.123.140`, uploads the bundle to the new server, runs OS provisioning (`2-provision-new-server.sh`), restores repos/DBs/certs/containers (`3-restore-and-start.sh`), and finishes with a read-only verification audit (`audit-server.sh`).
2. **`audit-server.sh` (100% Read-Only):**
   Connects via SSH (or runs locally) and prints the live server state (`dpkg -V` across the entire filesystem, manual APT packages, crontabs, Docker containers/volumes, and untracked files in `/var/www`) without writing or modifying anything on the server.
3. **`1-export-state.sh` (Read-Only Pull from Old Server):**
   Pulls all non-Git state from the old server into `./bundle/` (which is gitignored):
   - Latest PostgreSQL dumps (`Scout2DB`, `synora`, `Scout2DBPlayground`)
   - Let's Encrypt certificates (`/var/www/proxy/certbot`)
   - Static site (`/var/www/codeeve/html`) and `/var/www/common/olx`
   - Untracked `.env` files (`synora/.env`, `scout/eMo.API/.env*`)
   - `rclone.conf`, `~/.ssh` keys, and the `cloudflared` tunnel token
4. **`2-provision-new-server.sh` (Run on Fresh Ubuntu 24.04 Droplet):**
   Configures user `seidme` (seeding `~/.ssh/authorized_keys` from `root`), 4 GB `/swapfile`, `journald.conf` (`SystemMaxUse=200M`), Docker CE + Compose plugin, `rclone`, and `/var/www` permissions.
5. **`3-restore-and-start.sh` (Run on New Server After Upload):**
   Restores SSH keys, `rclone.conf`, clones all GitHub repositories on their target branches, restores `.env` files, Let's Encrypt certificates, and PostgreSQL databases, starts all Docker stacks + `cloudflared`, and installs the crontab.

---

## 3. Migration Runbook

### Option A: One-Command Automatic Migration (From Your Mac)
```bash
./0-migrate-all.sh <NEW_SERVER_IP>
```

### Option B: Step-by-Step Manual Execution
```bash
# Step 1: On your local machine, pull the state bundle from the current server
./1-export-state.sh seidme@159.65.123.140

# Step 2: Copy migration scripts + bundle to the new Ubuntu 24.04 server
scp -r ../server-migrate root@<NEW_SERVER_IP>:/root/server-migrate

# Step 3: SSH into the new server and provision the OS & tools
ssh root@<NEW_SERVER_IP> "bash /root/server-migrate/2-provision-new-server.sh"

# Step 4: Restore repositories, databases, certs, and start all Docker stacks
ssh seidme@<NEW_SERVER_IP> "bash /var/www/server-migrate/3-restore-and-start.sh /var/www/server-migrate/bundle"

# Step 5: Verify new server matches production state
./audit-server.sh seidme@<NEW_SERVER_IP>
```

---

## 4. Pre-Flight & Post-Migration Cutover Checklist (Outside the Scripts)

The scripts handle 100% of inside-the-server configuration. Before and after running them, check these external items:

1. **Pre-Flight (New Cloud Provider):**
   - Create an **Ubuntu 24.04 LTS (`x86_64`)** instance with your SSH public key added to `root`.
   - Ensure inbound firewall rules allow TCP ports **`22` (SSH)**, **`80` (HTTP)**, and **`443` (HTTPS)** (keep `5432` and `3000` closed externally if not needed publicly, or match your current firewall).
2. **Smoke-Test Before Switching DNS:**
   - Verify all containers are healthy (`ssh seidme@<NEW_SERVER_IP> "docker ps"`).
   - Test HTTPS routing against the new IP directly from your Mac before touching DNS:
     ```bash
     curl -Ik --resolve codeeve.com:443:<NEW_SERVER_IP> https://codeeve.com
     curl -Ik --resolve scout.codeeve.com:443:<NEW_SERVER_IP> https://scout.codeeve.com
     curl -Ik --resolve synora.codeeve.com:443:<NEW_SERVER_IP> https://synora.codeeve.com
     ```
3. **Stop `cloudflared` on the Old Server:**
   - Both servers share the same Cloudflare Tunnel token (`cloudflared_cmd.txt`). Stop the tunnel container on the old DigitalOcean droplet so it does not compete with the new server:
     ```bash
     ssh seidme@159.65.123.140 "docker stop cloudflared"
     ```
4. **Switch DNS (`A` Records):**
   - In your DNS provider (Cloudflare), update the `A` records pointing from `159.65.123.140` to `<NEW_SERVER_IP>` for:
     - `codeeve.com`
     - `emo.codeeve.com`
     - `flxng.codeeve.com`
     - `piker.codeeve.com`
     - `scout.codeeve.com`
     - `synora.codeeve.com`
     - `video.codeeve.com`
5. **Update GitHub Actions CI/CD Secrets:**
   - Because `/home/seidme/.ssh/authorized_keys` and `github_actions_key` are migrated identically, **no SSH keys need to be regenerated**.
   - Only update the server IP secret (e.g. `HOST` / `SERVER_IP` / `DROPLET_IP`) to `<NEW_SERVER_IP>` in your GitHub repositories (`scout`, `synora`, `flxng`, `video-downloader`, `docker-proxy-and-shared-network-utils`).
6. **Post-Cutover Cleanup:**
   - Remove the temporary staging bundle from the new server once everything is verified:
     ```bash
     ssh root@<NEW_SERVER_IP> "rm -rf /root/server-migrate /var/www/server-migrate/bundle"
     ```
   - Keep the old DigitalOcean droplet powered off (or running idle) for 24–48 hours while DNS caches expire before destroying it.

