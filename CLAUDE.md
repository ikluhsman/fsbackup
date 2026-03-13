# CLAUDE.md — fsbackup

Rsync-based snapshot backup system for a home lab. Runs on a Linux host as the `fsbackup` user via systemd timers. Snapshots are taken over SSH, stored locally on `/backup`, mirrored to `/backup2`, and (Phase 6, in progress) exported to S3.

---

## Repo Layout

```
bin/          Core backup scripts (runner, promote, mirror, retention, doctor, etc.)
conf/         Config templates (targets.yml.example, fsbackup.conf.example)
docs/         User-facing documentation
remote/       Scripts that run ON remote hosts, not the backup server
s3/           S3 export script (Phase 6 — in active development)
systemd/      Systemd unit files (source of truth; deploy to /etc/systemd/system/)
utils/        Manual/administrative utilities (restore, trust-host, etc.)
```

---

## Key Paths (Live System)

| Purpose | Path |
|---------|------|
| Installed config | `/etc/fsbackup/fsbackup.conf` |
| Targets file | `/etc/fsbackup/targets.yml` |
| age public key | `/etc/fsbackup/age.pub` |
| age private key | `/etc/fsbackup/age.key` (**NOT on server in production**) |
| AWS credentials | `/var/lib/fsbackup/.aws/credentials` (profile: `fsbackup`) |
| Primary snapshots | `/backup/snapshots/` |
| Mirror snapshots | `/backup2/snapshots/` |
| Logs | `/var/lib/fsbackup/log/` |
| Node exporter metrics | `/var/lib/node_exporter/textfile_collector/` |
| fsbackup user home | `/var/lib/fsbackup/` |

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

Scripts source this with: `source /etc/fsbackup/fsbackup.conf`

---

## Data Classes

| Class | Description | Schedule |
|-------|-------------|----------|
| class1 | Application data, personal files, DBs | Daily |
| class2 | Infrastructure config (docker stacks, nginx, bind, etc.) | Daily |
| class3 | Photo snapshots from /share/pictures | Monthly (1st of month) |

class3 is excluded from mirroring (`MIRROR_SKIP_CLASSES`). Only class1 gets annual snapshots.

---

## Script Roles

| Script | Location | Called From |
|--------|----------|-------------|
| `fs-runner.sh` | `bin/` | systemd timer |
| `fs-doctor.sh` | `bin/` | systemd timer |
| `fs-promote.sh` | `bin/` | systemd timer |
| `fs-annual-promote.sh` | `bin/` | systemd timer (Jan 5) |
| `fs-retention.sh` | `bin/` | systemd timer |
| `fs-mirror.sh` | `bin/` | systemd timer |
| `fs-mirror-retention.sh` | `bin/` | systemd timer |
| `fs-db-export.sh` | `bin/` | systemd timer |
| `fs-logrotate-metric.sh` | `bin/` | systemd timer |
| `fs-restore.sh` | `utils/` | manual only |
| `fs-trust-host.sh` | `utils/` | manual only |
| `fs-nodeexp-fix.sh` | `utils/` | manual only |
| `fs-annual-mirror-check.sh` | `utils/` | manual only |
| `fs-target-rename.sh` | `utils/` | manual only |
| `fs-export-s3.sh` | `s3/` | systemd timer at 04:30 (enabled, running nightly) |
| `fsbackup_remote_init.sh` | `remote/` | run ON remote host to set up backup user |
| `fs-prometheus-prebackup.sh` | `remote/` | run ON denhpsvr1 |
| `fs-victoriametrics-prebackup.sh` | `remote/` | run ON denhpsvr1 |

---

## Systemd Units

All units in `systemd/` are the source of truth. To deploy changes:

```bash
sudo cp /opt/fsbackup/systemd/*.service /opt/fsbackup/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

Units use template instantiation (`@class1`, `@class2`, `@class3`) for runner and doctor.

---

## Coding Conventions

- All scripts: `#!/usr/bin/env bash` + `set -u` + `set -o pipefail` (no `set -e` — errors handled per-iteration)
- Source config at top: `. /etc/fsbackup/fsbackup.conf` (dot-source, not `source`)
- Log to file with timestamps: `echo "$(date -Is) [$TARGET_ID] message" >> "$LOG_FILE"`
- Emit Prometheus metrics via the pattern established in `fs-runner.sh` (write `.prom` files to node exporter textfile dir)
- AWS CLI calls use `--profile fsbackup` and run as the `fsbackup` user
- All scripts that run as daemons/timers live in `bin/`; one-shot admin tools live in `utils/`

---

## S3 Export (Phase 6 — Active Development)

- Upload format: `tar | zstd -6 | age -e -R age.pub` → `<target>--<date>.tar.zst.age`
- Encryption: age public-key encryption (`/etc/fsbackup/age.pub` on server, private key stored off-server)
- Transit: HTTPS via AWS CLI (automatic); at-rest: SSE-S3 (AES-256) on bucket
- Bucket: `fsbackup-snapshots-SUFFIX` (us-west-2, private, versioning enabled)
- IAM user `fsbackup-uploader`: PutObject + GetObject + ListBucket only; no delete
- AWS credentials: profile `fsbackup` in `/var/lib/fsbackup/.aws/`
- Tiers uploaded: weekly + monthly + annual only (no daily, no class3)
- Idempotent: `head-object` check before each upload; safe to re-run
- Script: `s3/fs-export-s3.sh` — timer: `fsbackup-s3-export.timer` at 04:30 daily (enabled, running nightly)

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
- `fsbackup-s3-export.timer`: enabled and running nightly at 04:30.
- `grafana.data` target: fails nightly with rsync exit 24 (vanishing source file: `grafana.db-journal` — SQLite WAL artifact). Fix options: exclude the file in `targets.yml`, or stop Grafana briefly during backup window. Snapshot data itself transfers cleanly.

---

## Targets (targets.yml)

Not committed to git (`.gitignore`). Use `conf/targets.yml.example` as reference. Live file: `/etc/fsbackup/targets.yml`.

Hosts: `fs`, `denhpsvr1`, `denhpsvr2`, `hs`, `ns1`, `ns2`, `rp`, `weewx`, `mdns`

rsync `exclude` paths are **relative to the source path**, not the remote root.

---

## Web UI (`web/`)

FastAPI + HTMX + Tailwind app running as the `fsbackup` user via `fsbackup-web.service`.

- **Log viewer** (`/run` page): reads from log files in `/var/lib/fsbackup/log/`, not journalctl. Unit-to-log mapping is `_UNIT_LOG_MAP` in `web/main.py`. Includes the previous night's uncompressed rotated file (via `delaycompress` logrotate glob) to give ~1–2 nights of history.
- **Required groups for `fsbackup` user**: `fsbackup`, `nodeexp_txt`, `dbexports`, `systemd-journal` (journal fallback). `web/install.sh` handles all of these.
- **Restart required** after any group membership change: `systemctl restart fsbackup-web.service`

## Git / Deployment

- Working repo: `/opt/fsbackup` (owned `crash:crash`, scripts `755`)
- Bare remote: `/var/www/src/fsbackup.git` (served via Apache mod_git)
- `conf/targets.yml` is gitignored — never commit it
- `conf/grafana-dashboard.json` has instance-specific datasource UID; importers must remap
