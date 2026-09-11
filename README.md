# IT Infrastructure & DevOps Trainee — Practical Implementation Assignment

Public repository: https://github.com/AashishChaudhari/DevOps-Trainee

## Architecture Overview

```
                 ┌────────────────────────────────────────────┐
                 │                 AWS EC2 (Ubuntu)             │
Client ──80──▶  │  Nginx (reverse proxy) ──▶ Flask app :5000   │
                 │                              │                │
                 │                              ▼                │
                 │                        PostgreSQL (pgdata)    │
                 │                                               │
                 │  Node Exporter :9100 ──▶ Prometheus :9090     │
                 └────────────────────────────────────────────┘
```

- **Nginx** is the only container exposed on the host (port 80) and reverse-proxies all traffic to the Flask backend.
- **Flask app** and **PostgreSQL** are internal-only (`expose`, not `ports`) — not directly reachable from outside the Docker network. This is a deliberate defense-in-depth choice beyond the minimum spec.
- **Prometheus + Node Exporter** provide basic system metrics, restricted to admin IP access only (no built-in auth on Prometheus).

## Prerequisites

- Ubuntu 22.04/24.04 (tested on AWS EC2 `t2.micro`)
- Docker Engine 29.x and Docker Compose v2 (`docker compose` plugin)
- An SSH client and a generated ed25519 keypair

---

## Task 1: System Provisioning & Linux Administration

### What was done
- Created a dedicated `trainee` user and added it to the `sudo` group.
- Disabled root SSH login and password authentication; configured key-based auth only.
- Moved SSH to port `2222` instead of the default `22`.
- Enabled UFW, allowing only ports `2222` (SSH), `80` (HTTP), and `443` (HTTPS).
- Matched the same rules at the AWS Security Group layer (UFW alone is not sufficient on EC2 — both layers must agree).

### Key commands
```bash
sudo adduser trainee
sudo usermod -aG sudo trainee

# Key-based auth
sudo mkdir -p /home/trainee/.ssh
# (public key placed in /home/trainee/.ssh/authorized_keys)
sudo chown -R trainee:trainee /home/trainee/.ssh
sudo chmod 700 /home/trainee/.ssh
sudo chmod 600 /home/trainee/.ssh/authorized_keys

# SSH hardening (/etc/ssh/sshd_config)
Port 2222
PermitRootLogin no
PasswordAuthentication no
sudo systemctl restart ssh

# Firewall
sudo apt install ufw -y
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

### Verification
```bash
$ id trainee
uid=1001(trainee) gid=1001(trainee) groups=1001(trainee),27(sudo),100(users)

$ sudo grep -E "^Port|^PermitRootLogin|^PasswordAuthentication" /etc/ssh/sshd_config
Port 2222
PermitRootLogin no
PasswordAuthentication no

$ sudo ufw status verbose
Status: active
Default: deny (incoming), allow (outgoing), disabled (routed)
To                         Action      From
2222/tcp                   ALLOW IN    Anywhere
80/tcp                     ALLOW IN    Anywhere
443/tcp                    ALLOW IN    Anywhere
```

Root login over SSH was tested directly and confirmed refused (`Permission denied (publickey)`), and key-based login as `trainee` on port `2222` was confirmed working.

**Screenshots:**

![UFW status, id trainee, and sshd_config verification](screenshots/task1-ufw-id-sshd.png)

*Still to add: SSH login success as `trainee` on port 2222, refused root login attempt, AWS Security Group inbound rules panel.*

---

## Task 2: Containerization & Web Services

### What was done
A three-service stack was deployed with Docker Compose:
- `nginx` — reverse proxy, only service bound to a host port (`80:80`)
- `app` — a Flask application connecting to PostgreSQL, internal-only on port `5000`
- `db` — PostgreSQL with a named volume (`pgdata`) for persistence across restarts

### Setup
```bash
cd ~/devops-assignment
docker compose up -d --build
```

Relevant `docker-compose.yml` excerpt:
```yaml
services:
  nginx:
    image: nginx:latest
    ports:
      - "80:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - app

  app:
    build: ./app
    expose:
      - "5000"
    environment:
      DB_HOST: db
      DB_NAME: ${POSTGRES_DB}
      DB_USER: ${POSTGRES_USER}
      DB_PASSWORD: ${POSTGRES_PASSWORD}
    depends_on:
      - db

  db:
    image: postgres:16
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

Nginx reverse proxy config (`nginx/default.conf`):
```nginx
server {
    listen 80;
    location / {
        proxy_pass http://app:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

### Verification
```bash
$ docker ps
CONTAINER ID   IMAGE          STATUS         PORTS                  NAMES
...            nginx:latest   Up             0.0.0.0:80->80/tcp     nginx_proxy
...            devops-app     Up                                     flask_app
...            postgres:16    Up                                     postgres_db

$ curl http://localhost/
{"message":"Hello from Flask! Reverse proxy is working."}

$ curl http://localhost/health
{"status":"ok","db":"connected"}
```

Externally verified from a separate client machine (`curl.exe -v` from a Windows laptop, outside the AWS network) returned a clean `200 OK` with the same JSON payload — confirming the reverse proxy path works end-to-end, not just on `localhost`.

**Screenshots:**

![Docker and Docker Compose versions installed](screenshots/task2-docker-version.png)
![Browser response through the reverse proxy](screenshots/task2-browser-response.png)

*Still to add: `docker ps` showing all three containers, `docker volume ls` showing the persistent `pgdata` volume, external `curl -v` verification.*

---

## Task 3: Automation & Shell Scripting

### What was done
`/opt/scripts/infra_health_check.sh` checks CPU, RAM, and root disk usage, and the running status of all three application containers (`flask_app`, `nginx_proxy`, `postgres_db`). If disk usage exceeds 85% or any container is down, it prints a `[WARNING]` to the terminal and appends a timestamped entry to `/var/log/infra_health.log`. A cron job runs it every 15 minutes.

### Setup
```bash
sudo chmod +x /opt/scripts/infra_health_check.sh
sudo crontab -e
# added:
*/15 * * * * /opt/scripts/infra_health_check.sh >> /var/log/infra_health_cron.log 2>&1
```

### Verification — normal run
```
===== Infra Health Check: 2026-09-11 12:10:43 =====
CPU Usage: 4.5%
RAM Usage: 50.98%
Disk Usage (/): 59%
Docker service: running
Container 'flask_app': running
Container 'nginx_proxy': running
Container 'postgres_db': running
All checks passed. No issues detected.
```

### Verification — warning path (container stopped intentionally)
```
$ docker stop nginx_proxy
$ sudo /opt/scripts/infra_health_check.sh
[WARNING] Container 'nginx_proxy' is stopped or not found.

$ cat /var/log/infra_health.log
2026-09-11 12:11:32 [WARNING] Container 'nginx_proxy' is stopped or not found.
```
Container was restarted afterward with `docker start nginx_proxy`.

### Verification — cron actually firing automatically
```
$ sudo crontab -l
*/15 * * * * /opt/scripts/infra_health_check.sh >> /var/log/infra_health_cron.log 2>&1

$ cat /var/log/infra_health_cron.log
===== Infra Health Check: 2026-09-11 12:15:01 =====
... All checks passed. No issues detected.
===== Infra Health Check: 2026-09-11 12:30:01 =====
... All checks passed. No issues detected.
===== Infra Health Check: 2026-09-11 12:45:01 =====
...
```
Three separate automatic runs, 15 minutes apart, confirm the cron job is active and functioning without manual intervention.

**Screenshots:**

![Health check script: normal run and warning-triggered run after stopping a container](screenshots/task3-healthcheck-normal-and-warning.png)
![Warning entry appended to infra_health.log](screenshots/task3-log-file.png)
![Registered cron job](screenshots/task3-crontab.png)
![Cron log showing automatic runs every 15 minutes](screenshots/task3-cron-log.png)

---

## Task 4: Monitoring, Backups & Disaster Recovery

### Backup script
`/opt/scripts/db_backup.sh` dumps the PostgreSQL database from the `postgres_db` container, compresses it, and stores it in `/var/backups/db/` with a timestamped filename. Backups older than 7 days are automatically deleted (retention policy).

> **Note on file extension:** the spec suggests `.tar.gz`, but `pg_dump | gzip` produces a `.sql.gz` file, which is the correct and standard way to compress a single SQL dump. `tar` is for bundling multiple files/directories, which doesn't apply here — `db_backup_YYYYMMDD.sql.gz` is used instead, preserving the same date-stamped naming convention.

```bash
$ sudo /opt/scripts/db_backup.sh
Starting backup of 'appdb' at 2026-09-11 21:03:40...
Backup successful: /var/backups/db/db_backup_20260911.sql.gz (4.0K)
Old backups (older than 7 days) cleaned up.

$ ls -lh /var/backups/db/
-rw-r--r-- 1 root root 824 Sep 11 21:03 db_backup_20260911.sql.gz
```

### Restore procedure (documented and tested)
```bash
# 1. Stop the app so it doesn't write during restore
docker compose stop app

# 2. Decompress and restore into the running Postgres container
gunzip -c /var/backups/db/db_backup_20260911.sql.gz | docker exec -i postgres_db psql -U appuser -d appdb

# 3. Restart the app
docker compose start app
```

This was tested end-to-end as a full disaster-recovery drill:
1. A test table with data was created and backed up.
2. The table was deliberately dropped (`DROP TABLE test_data;`) to simulate data loss.
3. The restore command above was run against the live database.
4. `SELECT * FROM test_data;` confirmed the row was successfully recovered.

### Basic metrics/monitoring — Prometheus + Node Exporter
Node Exporter collects host-level system metrics (CPU, memory, disk, etc.) and Prometheus scrapes them every 15 seconds.

```yaml
  node_exporter:
    image: prom/node-exporter:latest
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    expose:
      - "9100"

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    ports:
      - "9090:9090"
```

Prometheus UI is exposed only to the admin's IP (not `0.0.0.0/0`), since Prometheus ships with no built-in authentication:
```bash
sudo ufw allow from <admin-ip> to any port 9090 proto tcp
```
(matching rule also added at the AWS Security Group level)

### Verification
- `docker compose ps` shows `node_exporter` and `prometheus` running alongside the original three services.
- Prometheus **Status → Targets** page shows `node_exporter` as **UP** (1/1 targets healthy, ~15s scrape interval, ~16ms scrape duration).
- A live query for `node_memory_MemAvailable_bytes` returns real, non-zero data — confirming metrics are actively flowing, not just that the container is running.

**Screenshots:**

![Backup script running successfully](screenshots/task4-backup-success.png)
![Prometheus Targets page showing node_exporter UP](screenshots/task4-prometheus-targets-up.png)

*Still to add: full restore sequence (drop table → restore → data recovered), `docker compose ps` showing all five containers including node_exporter and prometheus, a live Prometheus metrics query result.*

---

## Task 5: Git & Documentation

### Branch strategy
```
main
 ├─ feature/docker-setup   → Nginx, Flask, Postgres, docker-compose.yml
 └─ feature/scripts        → infra_health_check.sh, db_backup.sh
```
Both feature branches were committed independently and merged into `main` with descriptive commit messages.

```bash
$ git log --oneline --graph --all
* abf0d22 (main) Add Prometheus and Node Exporter monitoring configuration
* 1b5b16b (feature/scripts) Add infra health check and database backup scripts
* 9186002 (feature/docker-setup) Initial commit: project structure
```

All three branches are pushed to the public repository:
```bash
git push -u origin main
git push origin feature/docker-setup
git push origin feature/scripts
```

**Screenshots:**

*Still to add: `git log --oneline --graph --all` output, GitHub repo branch dropdown showing all three branches.*

---

## Teardown

```bash
cd ~/devops-assignment
docker compose down -v   # -v also removes named volumes (pgdata, prometheus_data)
```

## Design Decisions Summary

- Only Nginx is exposed on a host port; the app and database stay internal to the Docker network (defense-in-depth beyond the minimum spec).
- Database backups use `.sql.gz` instead of the literally-specified `.tar.gz`, since `gzip` is the correct tool for compressing a single SQL dump file — `tar` is meant for bundling multiple files/directories.
- Prometheus's web UI is IP-restricted at both the UFW and AWS Security Group level, since it has no built-in authentication.
- The health-check script monitors all three original containers (not just one), giving broader coverage than the minimum requirement.
