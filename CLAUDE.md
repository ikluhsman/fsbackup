# CLAUDE.md — fsbackup

Rsync-based snapshot backup system for a home lab. Runs as the `fsbackup` user inside a Docker container (supercronic scheduler + FastAPI web UI). Snapshots are taken over SSH, stored locally on `/backup`, mirrored to `/backup2`, and exported to S3 (weekly/monthly/annual).

---

## Repo Layout

```
bin/          Core backup scripts (runner, promote, mirror, retention, doctor, etc.)
conf/         Config templates (targets.yml.example, fsbackup.conf.example, docker-compose.yml.example)
docker/       Docker entrypoint script
docs/         User-facing documentation
remote/       Scripts that run ON remote hosts, not the backup server
s3/           S3 export script
systemd/      Systemd unit files (kept for reference; not used in Docker deployment)
utils/        Manual/administrative utilities (restore, trust-host, etc.)
web/          FastAPI + HTMX web UI
```

---

## Key Paths (Live System)

| Purpose | Path |
|---------|------|
| Installed config | `/etc/fsbackup/fsbackup.conf` |
| Targets file | `/etc/fsbackup/targets.yml` |
| Crontab (supercronic) | `/etc/fsbackup/fsbackup.crontab` |
| age public key | `/etc/fsbackup/age.pub` |
| age private key | `/etc/fsbackup/age.key` (**NOT on server in production**) |
| AWS credentials | `/var/lib/fsbackup/.aws/credentials` (profile: `fsbackup`) |
| SSH keys | `/var/lib/fsbackup/.ssh/` (id_ed25519_backup + known_hosts) |
| Primary snapshots | `/backup/snapshots/` |
| Mirror snapshots | `/backup2/snapshots/` |
| DB exports | `/backup/exports/` |
| Logs | `/var/lib/fsbackup/log/` |
| Node exporter metrics | `/var/lib/node_exporter/textfile_collector/` |

**Snapshot path structure:** `/backup/snapshots/<tier>/<date>/<class>/<target>/`
- Tiers: `daily`, `weekly`, `monthly`, `annual`
- Date formats: `YYYY-MM-DD` (daily), `YYYY-Www` (weekly), `YYYY-MM` (monthly), `YYYY` (annual)

---

## fsbackup.conf Keys

```bash
SNAPSHOT_ROOT="/backup/snapshots"
SNAPSHOT_MIRROR_ROOT="/backup2/snapshots"
MIRROR_SKIP_CLASSES="class3"      # space-separated list of classes not mirrored
```

Scripts source this with: `. /etc/fsbackup/fsbackup.conf`

---

## Data Classes

| Class | Description | Schedule |
|-------|-------------|----------|
| class1 | Application data, personal files, DBs | Daily |
| class2 | Infrastructure config (docker stacks, nginx, bind, etc.) | Daily |
| class3 | Large archives (photos, video libraries, media collections, etc.) | Monthly (1st of month) |

class3 mirroring is optional — controlled by `MIRROR_SKIP_CLASSES` in `fsbackup.conf`. Set to `"class3"` to exclude from mirroring, or leave empty to mirror everything. Only class1 gets annual snapshots.

---

## Script Roles

| Script | Location | Called From |
|--------|----------|-------------|
| `fs-runner.sh` | `bin/` | supercronic |
| `fs-doctor.sh` | `bin/` | supercronic |
| `fs-promote.sh` | `bin/` | supercronic |
| `fs-annual-promote.sh` | `bin/` | supercronic (Jan 5) |
| `fs-retention.sh` | `bin/` | supercronic |
| `fs-mirror.sh` | `bin/` | supercronic |
| `fs-mirror-retention.sh` | `bin/` | supercronic |
| `fs-db-export.sh` | `bin/` | supercronic |
| `fs-restore.sh` | `utils/` | manual only |
| `fs-trust-host.sh` | `utils/` | manual only (works as root or fsbackup user) |
| `fs-nodeexp-fix.sh` | `utils/` | manual only |
| `fs-annual-mirror-check.sh` | `utils/` | manual only |
| `fs-target-rename.sh` | `utils/` | manual only |
| `fs-export-s3.sh` | `s3/` | supercronic at 04:30 daily |
| `fsbackup_remote_init.sh` | `remote/` | run ON remote host to set up backup user |
| `fs-prometheus-prebackup.sh` | `remote/` | run ON denhpsvr1 |
| `fs-victoriametrics-prebackup.sh` | `remote/` | run ON denhpsvr1 |

---

## Docker Deployment

Live stack runs from `/docker/stacks/fsbackup/docker-compose.yml`. Image: `ghcr.io/fsbackup/fsbackup`.

### Build & push
Images are published automatically to `ghcr.io/fsbackup/fsbackup` via GitHub Actions when a version tag is pushed:
```bash
git tag -a v0.9.2 -m "v0.9.2 — description"
git push origin v0.9.2
```
To build locally: `docker build -t fsbackup:latest .`

### Key compose settings
- `user: "993:993"` — must match fsbackup UID/GID on host
- `extra_hosts:` — pin all remote hostnames to IPs to avoid DNS failures from Linux 6.8 FIB exception bug
- `AUTH_PASSWORD_HASH` in `web/.env`: bcrypt `$` signs must be escaped as `$$` (Docker Compose v2 interpolation)

### Volumes (bind mounts required)
- `/etc/fsbackup` — config, targets.yml, crontab, age.pub
- `/backup/snapshots`, `/backup2/snapshots` — snapshot storage
- `/backup/exports` — DB exports
- `/var/lib/node_exporter/textfile_collector` — Prometheus .prom files
- `/var/lib/fsbackup` (or named volume) — SSH keys, AWS creds, logs
- localhost source paths (e.g. `/share/technicom`, `/docker/volumes/...`) must also be bind-mounted

### Scheduler
supercronic reads `/etc/fsbackup/fsbackup.crontab` (bind-mounted from host). Edit on host; supercronic hot-reloads.

### SSH host keys
```bash
# Inside container (after fs-trust-host.sh root requirement was relaxed):
docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh <hostname>
# Or directly on host (bind-mounted path):
ssh-keyscan -t ed25519 <hostname> >> /var/lib/fsbackup/.ssh/known_hosts
```

---

## Coding Conventions

- All scripts: `#!/usr/bin/env bash` + `set -u` + `set -o pipefail` (no `set -e` — errors handled per-iteration)
- Source config at top: `. /etc/fsbackup/fsbackup.conf` (dot-source, not `source`)
- Log to file with timestamps: `echo "$(date -Is) [$TARGET_ID] message" >> "$LOG_FILE"`
- Emit Prometheus metrics via the pattern established in `fs-runner.sh` (write `.prom` files to node exporter textfile dir)
- Prom file permissions: `chgrp nodeexp_txt ... 2>/dev/null || true` + `chmod 0644` — group may not exist in container
- AWS CLI calls use `--profile fsbackup` and run as the `fsbackup` user
- All scripts that run as daemons/timers live in `bin/`; one-shot admin tools live in `utils/`

---

## S3 Export

- Upload format: `tar | zstd -6 | age -e -R age.pub` → `<target>--<date>.tar.zst.age`
- Encryption: age public-key encryption (`/etc/fsbackup/age.pub` on server, private key stored off-server)
- Transit: HTTPS via AWS CLI (automatic); at-rest: SSE-S3 (AES-256) on bucket
- Bucket: `fsbackup-snapshots-SUFFIX` (us-west-2, private, versioning enabled)
- IAM user `fsbackup-uploader`: PutObject + GetObject + ListBucket only; no delete
- AWS credentials: profile `fsbackup` in `/var/lib/fsbackup/.aws/`
- Tiers uploaded: weekly + monthly + annual only (no daily, no class3)
- Idempotent: `head-object` check before each upload; safe to re-run
- Script: `s3/fs-export-s3.sh` — runs nightly at 04:30 via supercronic

**S3 key:** `<tier>/<class>/<target>/<target>--<date>.tar.zst.age`
(tier is top-level prefix so lifecycle `Prefix:` rules work)

**Lifecycle rules:** `weekly/` → 84d, `monthly/` → 450d, `annual/` → no expiry

**Restore:**
```bash
aws s3 cp s3://fsbackup-snapshots-SUFFIX/<tier>/<class>/<target>/<archive>.tar.zst.age .
age -d -i /etc/fsbackup/age.key <archive>.tar.zst.age | zstd -d | tar -xf - -C /restore/path/
```

---

## Known Issues / Open Work

- `conf/ssh_config.example`: Only has `Host hs` stanza. Other hosts use default key.
- `utils/fs-annual-mirror-check.sh`: No timer wires it up yet.
- class3 `system.*` targets (all hosts) removed pending proper host-expansion feature.
- `grafana.data` target: fails nightly with rsync exit 24 (vanishing source file: `grafana.db-journal` — SQLite WAL artifact). Fix: exclude the file in `targets.yml`.

---

## Targets (targets.yml)

Not committed to git (`.gitignore`). Use `conf/targets.yml.example` as reference. Live file: `/etc/fsbackup/targets.yml`.

Hosts: `fs` (localhost in Docker), `denhpsvr1`, `denhpsvr2`, `hs`, `ns1`, `ns2`, `rp`, `weewx`, `mdns`

rsync `exclude` paths are **relative to the source path**, not the remote root.

`host: fs` targets use `host: localhost` in Docker — the container accesses local paths directly via bind mounts.

---

## Web UI (`web/`)

FastAPI + HTMX + Tailwind. Deployed via Docker (uvicorn inside container).

- `web/.env`: `HOST=0.0.0.0`, `PORT=8080`, `AUTH_ENABLED=true`, `AUTH_PASSWORD_HASH=<bcrypt>`
- bcrypt `$` characters in `AUTH_PASSWORD_HASH` must be escaped as `$$` in `.env` (Docker Compose v2 interpolation)
- Auth: bcrypt password hash — no PAM/shadow group dependency
- `/static/` exempt from auth — required so favicon/logos load on the login page

## Git / Deployment

- Working repo: `/home/crash/fsbackup` (owned `crash:crash`, scripts `755`)
- Live stack: `/docker/stacks/fsbackup/docker-compose.yml`
- Remote: `git@github.com:fsbackup/fsbackup.git` (public, under fsbackup org)
- Docs site repo: `github.com/fsbackup/fsbackup-docs` (Nuxt 4, domain: fsbackup.org)
- `conf/targets.yml` is gitignored — never commit it
- `conf/grafana-dashboard.json` has instance-specific datasource UID; importers must remap
- Version tags (`v*.*.*`) trigger GitHub Actions to build and push to `ghcr.io/fsbackup/fsbackup`
- current release is v1.0.2

## Host Networking — Linux 6.8 FIB Exception Bug

Cross-VLAN connections intermittently fail when the kernel creates per-uid FIB exceptions
tagged RTN_BROADCAST, causing EACCES/ENETUNREACH even when static routes exist.

**Mitigations in place:**
- Explicit per-VLAN static routes in `/etc/netplan/00-enp2s0f-config.yaml`
- `accept_redirects=0` in `/etc/sysctl.d/99-routing.conf`
- `fib-monitor.service` running — polls every 30s, logs to `/var/log/fib-exception.log` on detection

**Manual flush when symptoms appear:**
```bash
sudo ip route flush cache
```

**Docker mitigation:** use `extra_hosts:` in stack compose to pin hostnames to IPs, bypassing
DNS for rsync targets so container jobs don't fail even if host DNS is temporarily broken.

**Suspects for exception creation:** Avahi (`enable-reflector=yes` on enp2s0f0) and Plex
(multicast discovery traffic) — both send cross-VLAN packets that may trigger exceptions.
`fib-monitor.service` will capture which UID/process triggers it next time.
