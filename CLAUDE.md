# CLAUDE.md — fsbackup

ZFS-native rsync snapshot backup system for a home lab. Runs bare-metal on `fs` (172.30.3.130) as the `fsbackup` system user under systemd. Snapshots are taken over SSH (or locally), stored as ZFS snapshots, and exported to S3 (weekly/monthly/annual). No Docker, no supercronic.

---

## Repo Layout

```
bin/          Core backup scripts (runner, retention, doctor, provision, install, etc.)
conf/         Config templates (targets.yml.example, fsbackup.conf.example)
docs/         User-facing documentation
remote/       Scripts that run ON remote hosts, not the backup server
s3/           S3 export script
systemd/      Systemd unit and timer files
utils/        Manual/administrative utilities (restore, trust-host, target-rename, etc.)
web/          FastAPI + HTMX web UI
```

---

## Key Paths (Live System)

| Purpose | Path |
|---------|------|
| Installed config | `/etc/fsbackup/fsbackup.conf` |
| Targets file | `/etc/fsbackup/targets.yml` |
| DB export env files | `/etc/fsbackup/db/<name>.env` |
| age public key | `/etc/fsbackup/age.pub` |
| age private key | `/etc/fsbackup/age.key` (**NOT on server in production**) |
| AWS credentials | `/var/lib/fsbackup/.aws/credentials` (profile: `fsbackup`) |
| SSH keys | `/var/lib/fsbackup/.ssh/` (id_ed25519_backup + known_hosts) |
| Primary snapshots | `/backup/snapshots/` |
| DB exports | `/backup/exports/` |
| Logs | `/var/lib/fsbackup/log/` |
| Node exporter metrics | `/var/lib/node_exporter/textfile_collector/` |
| Sudoers drop-in | `/etc/sudoers.d/fsbackup-zfs-destroy` |

**ZFS dataset layout:** `backup/snapshots/<class>/<target>`
- e.g. `backup/snapshots/class1/paperlessngx.db`
- ZFS snapshots: `@daily-YYYY-MM-DD`, `@weekly-YYYY-Www`, `@monthly-YYYY-MM`
- Snapshot contents accessible read-only via `.zfs/snapshot/<name>/`

---

## fsbackup.conf Keys

```bash
SNAPSHOT_ROOT="/backup/snapshots"   # ZFS dataset root = strip leading /
CLASS1_DAILY_SCHEDULE="*-*-* 01:49:00"
CLASS1_WEEKLY_SCHEDULE="Mon *-*-* 02:00:00"
CLASS1_MONTHLY_SCHEDULE="*-*-01 02:00:00"
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12
S3_BUCKET="fsbackup-snapshots-SUFFIX"
```

Scripts source this with: `. /etc/fsbackup/fsbackup.conf`

---

## Data Classes

| Class | Description | Schedule |
|-------|-------------|----------|
| class1 | Application data, personal files, DBs | Daily + weekly + monthly |
| class2 | Infrastructure config (docker stacks, nginx, bind, etc.) | Daily + weekly + monthly |
| class3 | Large archives (photos, video libraries, etc.) | Monthly only |

---

## Script Roles

| Script | Location | Called From |
|--------|----------|-------------|
| `fs-runner.sh` | `bin/` | systemd timer (`fsbackup-runner-daily@<class>`, etc.) |
| `fs-retention.sh` | `bin/` | systemd timer (`fsbackup-retention.timer`) |
| `fs-provision.sh` | `bin/` | manual (create ZFS datasets from targets.yml) |
| `fs-doctor.sh` | `bin/` | systemd timer (`fsbackup-doctor@<class>.timer`) |
| `fs-install.sh` | `bin/` | manual (bare-metal installer; run as root) |
| `fs-schedule-apply.sh` | `bin/` | manual + installer (writes systemd OnCalendar= drop-ins) |
| `fs-db-export.sh` | `bin/` | systemd timer (`fs-db-export@<name>.timer`); runs as root |
| `fs-restore.sh` | `utils/` | manual only |
| `fs-trust-host.sh` | `utils/` | manual only |
| `fs-target-rename.sh` | `utils/` | manual + web UI (Configuration > Targets > Rename) |
| `fs-export-s3.sh` | `s3/` | systemd timer (`fsbackup-s3-export.timer`) |
| `fsbackup_remote_init.sh` | `remote/` | run ON remote host to set up backup user |

---

## Systemd Units

Parameterized by class instance (e.g. `@class1`):

| Unit | Purpose |
|------|---------|
| `fsbackup-runner-daily@.timer` | Daily rsync + ZFS snapshot |
| `fsbackup-runner-weekly@.timer` | Weekly rsync + ZFS snapshot |
| `fsbackup-runner-monthly@.timer` | Monthly rsync + ZFS snapshot |
| `fsbackup-doctor@.timer` | SSH/path health check + orphan scan |
| `fsbackup-retention.timer` | Prune old ZFS snapshots |
| `fsbackup-s3-export.timer` | Encrypt + upload to S3 |
| `fsbackup-scrub.timer` | ZFS scrub |
| `fsbackup-logrotate-metric.timer` | Rotate Prometheus .prom files |
| `fsbackup-web.service` | FastAPI web UI (no timer; persistent) |
| `fs-db-export@.timer` | DB export; instance = env filename in /etc/fsbackup/db/ |

---

## Logging

Per-class runner logs: `/var/lib/fsbackup/log/backup-<class>.log`
Other logs in same dir: `s3-export.log`, `fs-orphans.log`

---

## Privilege Model

The `fsbackup` user runs most services. Exceptions:
- `fs-db-export@.service`: `User=root` (needs `docker exec`)
- Orphan dataset deletion in web UI: `sudo zfs destroy -r <dataset>` — allowed via `/etc/sudoers.d/fsbackup-zfs-destroy` (NOPASSWD, scoped to `SNAPSHOT_ROOT/*/*`). Created automatically by `fs-install.sh`.

---

## Coding Conventions

- All scripts: `#!/usr/bin/env bash` + `set -u` + `set -o pipefail` (no `set -e` — errors handled per-iteration)
- Source config at top: `. /etc/fsbackup/fsbackup.conf`
- Log with timestamps: `echo "$(date -Is) [$TARGET_ID] message" | tee -a "$LOG_FILE"`
- Prometheus metrics: write `.prom` files to node exporter textfile dir, then `mv` atomically
- Prom file permissions: `chgrp nodeexp_txt ... 2>/dev/null || true` + `chmod 0644`
- AWS CLI calls use `--profile fsbackup`

---

## Web UI (`web/`)

FastAPI + HTMX + Tailwind CDN. `fsbackup-web.service` on `0.0.0.0:8080`.

- `web/.env`: `HOST`, `PORT`, `AUTH_ENABLED`, `AUTH_PASSWORD_HASH` (bcrypt)
- Auth: bcrypt password hash; `/static/` exempt

### Pages

| Route | Description |
|-------|-------------|
| `/` | Dashboard — class status cards |
| `/snapshots` | Filterable snapshot browser; orphan rows highlighted red with inline delete |
| `/logs` | Log viewer (per-class sections) + Prometheus metrics table |
| `/restore` | Restore files from a snapshot |
| `/run` | Trigger runner/doctor/retention jobs |
| `/s3` | S3 offsite bucket browser |
| `/configuration` | Tabbed config: Hosts, Targets, Schedule, Volumes & Maintenance |
| `/browse` | Filesystem browser inside a snapshot |

---

## Git / Deployment

- Working repo: `/home/crash/projects/fsbackup` (owned `crash:crash`)
- Installed at: `/opt/fsbackup/` (owned `fsbackup:fsbackup`)
- Remote: `git@github.com:fsbackup/fsbackup.git`
- **main is branch-protected** — always branch + PR
- Deploy: `sudo rsync -a --delete --exclude='.git' --exclude='web/.venv' --exclude='web/.env' --exclude='conf/targets.yml' /home/crash/projects/fsbackup/ /opt/fsbackup/`
- `conf/targets.yml` is gitignored — never commit it
- Current release: **v2.0.1**

## Known Issues / Open Work

- `grafana.data` rsync fails nightly with exit 24 (`grafana.db-journal` vanishes mid-transfer). Fix: add `--exclude=grafana.db-journal` to target rsync_opts.
- Stale broken symlinks in `/etc/systemd/system/timers.target.wants/` for old v1.x units — harmless, can be cleaned up with `find /etc/systemd/system -xtype l -delete`.
- `#52` — parallel doctor runs, race on shared prom files (low priority)
- `#66` — TrueNAS SCALE support (backburner)
