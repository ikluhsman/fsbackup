# fsbackup

fsbackup is a pull-based ZFS snapshot backup system for home lab Linux servers. The backup host connects outbound over SSH to each source host, pulls data with rsync, and stores point-in-time snapshots as ZFS snapshots. Snapshots are optionally exported to encrypted offsite archives in S3. A [browser-based web UI](#web-ui) provides monitoring, snapshot browsing, and restore — including an S3 bucket browser.

fsbackup runs bare-metal as systemd services (no Docker, no supercronic). See [Installation](docs/installation.md) for setup.

---

## Features

- **Disk-to-disk snapshots over SSH** — pull-based rsync; the backup server initiates all connections, source hosts need only a read-only `backup` user
- **ZFS-native snapshot storage** — each backup run takes a ZFS snapshot (`@daily-YYYY-MM-DD`, `@weekly-YYYY-Www`, `@monthly-YYYY-MM`) on a per-target dataset; snapshots are space-efficient via ZFS copy-on-write and accessible read-only under `.zfs/snapshot/`
- **Multi-class scheduling** — daily, weekly, and monthly snapshot types per class; schedules are defined in `fsbackup.conf` and applied to systemd timers via `fs-schedule-apply.sh`
- **Configurable retention** — `fs-retention.sh` prunes old ZFS snapshots per class per KEEP_* policy (daily/weekly/monthly)
- **Database export tool** — `fs-db-export.sh` dumps PostgreSQL, MySQL, and MariaDB databases to a staging directory before backup runs, ensuring a consistent, closed database file in the snapshot
- **Encrypted offsite export to S3** — weekly, monthly, and annual snapshots are compressed with zstd, encrypted end-to-end with [age](https://github.com/FiloSottile/age), and uploaded to Amazon S3; the private key never touches the backup server
- **S3 lifecycle management** — retention on S3 is handled entirely by prefix-based lifecycle rules; the export script never deletes anything
- **Web UI** — FastAPI + HTMX dashboard for monitoring backup health, browsing snapshots, running jobs on demand, and initiating restores; includes an S3 bucket browser with one-click restore command generation
- **Prometheus metrics + Grafana dashboard** — every script emits textfile collector metrics covering snapshot size, file deltas, transfer bytes, exit codes, and timing; a pre-built Grafana dashboard is included
- **Health checks** — `fs-doctor.sh` verifies SSH connectivity, validates source paths, and detects orphaned datasets before each backup window

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| **Snapshots** | [ZFS](https://openzfs.org/) — copy-on-write snapshots, dataset-per-target layout |
| **Data transfer** | [rsync](https://rsync.samba.org/) over SSH — pull-based, incremental |
| **Scheduling** | [systemd](https://systemd.io/) timers — per-class instances, `OnCalendar=` schedules |
| **Encryption (offsite)** | [age](https://github.com/FiloSottile/age) — modern, audited encryption for S3 archives |
| **Compression (offsite)** | [zstd](https://facebook.github.io/zstd/) — fast compression before S3 upload |
| **Offsite storage** | [Amazon S3](https://aws.amazon.com/s3/) with prefix-based lifecycle rules |
| **Web UI backend** | [FastAPI](https://fastapi.tiangolo.com/) — async Python, serving HTMX partials |
| **Web UI frontend** | [HTMX](https://htmx.org/) + [Tailwind CSS](https://tailwindcss.com/) (CDN) — no build step |
| **Metrics** | [Prometheus](https://prometheus.io/) textfile collector via [node_exporter](https://github.com/prometheus/node_exporter) |
| **Dashboards** | [Grafana](https://grafana.com/) — pre-built dashboard included in `conf/` |
| **Config** | YAML (`targets.yml`) + bash (`fsbackup.conf`) |
| **Language** | Bash (scripts) + Python 3.12 (web UI) |

---

## How it works

1. A `backup` user is created on each source host with read-only SSH access to the directories being backed up.
2. The backup host runs rsync over SSH, pulling data into a per-target ZFS dataset (`backup/snapshots/<class>/<target>`).
3. After a successful rsync, a ZFS snapshot is taken on the dataset (e.g. `@daily-2026-03-29`). Unchanged blocks are shared automatically by ZFS copy-on-write — no hardlink bookkeeping needed.
4. `fs-retention.sh` prunes snapshots older than the configured KEEP_* limits using `zfs destroy`.
5. Prometheus metrics are written after each run so Grafana can show backup health at a glance.

---

## Table of contents

- [How it works](#how-it-works)
- [Web UI](#web-ui)
- [Repository layout](#repository-layout)
- [Data classes](#data-classes)
- [Snapshot layout](#snapshot-layout)
- [Scripts — automated](#scripts--automated-run-by-systemd)
- [Scripts — manual use](#scripts--manual-use-administrative-utilities)
- [Remote scripts](#remote-scripts)
- [S3 cloud export](#s3-cloud-export)
- [Daily schedule](#daily-schedule)
- [Prometheus metrics](#prometheus-metrics)
- [Restore](#restore)
- [Restore from S3](#restore-from-s3)
- [Further reading](#further-reading)

---

## Web UI

fsbackup includes a browser-based UI for monitoring backup status, browsing snapshots, running jobs on demand, and initiating restores. It runs as a FastAPI + HTMX app on the backup server.

**Dashboard** — live status of all targets and recent run outcomes:

![Dashboard](docs/screenshots/fsb_dashboard.png)

**Targets** — lists all configured targets with their class and host:

![Targets](docs/screenshots/fsb_targets.png)

**Snapshots** — browse available snapshots by class and date; orphaned datasets are highlighted inline:

![Snapshots](docs/screenshots/fsb_snapshots.png)

**Browse** — explore the file tree inside any snapshot:

![Browse](docs/screenshots/fsb_browse.png)

**Restore** — restore files from a snapshot to a local or remote path:

![Restore](docs/screenshots/fsb_restore.png)

**Run jobs** — trigger runner or doctor jobs manually and follow the log output:

![Run jobs](docs/screenshots/fsb_run_jobs.png)

**S3 browse** — list what's in the S3 bucket by tier, class, and target:

![S3 browse](docs/screenshots/fsb_s3_browse.png)

**S3 download** — generate a download command for any S3 archive:

![S3 download](docs/screenshots/fsb_s3_download.png)

---

## Repository layout

```
bin/        Scripts run automatically by systemd timers
utils/      Manual-use administrative tools
remote/     Scripts that run ON source hosts (not the backup server)
s3/         S3 cloud export
systemd/    Systemd service and timer unit files
conf/       Configuration templates, examples, and Grafana dashboard
web/        FastAPI + HTMX web UI
docs/       Detailed documentation
```

---

## Data classes

Targets (individual backup jobs) are grouped into classes. Each class has its own schedule and retention policy.

| Class | What it covers | Schedule | Snapshot types |
|-------|---------------|----------|----------------|
| class1 | Application data, databases, personal files | Daily | daily / weekly / monthly |
| class2 | Infrastructure config (Docker stacks, nginx, DNS, etc.) | Daily | daily / weekly / monthly |
| class3 | Photo archives and large infrequently-changed data | Monthly (1st of each month) | monthly only |

class3 is not included in S3 export. Offsite copies are made manually to USB and M-DISC.

---

## Snapshot layout

Snapshots are ZFS datasets and snapshots under the configured `SNAPSHOT_ROOT` (default `/backup/snapshots`).

```
backup/snapshots/              ← ZFS parent dataset
  class1/
    paperlessngx.db/           ← ZFS dataset per target
      @daily-2026-03-29        ← ZFS snapshot
      @weekly-2026-W13
      @monthly-2026-03
    homeassistant.db/
      @daily-2026-03-29
      ...
  class2/
    nginx.config/
      @daily-2026-03-29
      ...
  class3/
    photos/
      @monthly-2026-03
      ...
```

Snapshot contents are accessible read-only at `<dataset>/.zfs/snapshot/<name>/`.

---

## Scripts — automated (run by systemd)

These scripts are called by systemd timers on a schedule. You generally don't run them by hand, though most support `--dry-run`. To run manually: `sudo -u fsbackup /opt/fsbackup/bin/<script> ...`

Repository path: **bin/**

| Filename | Name | Description |
|----------|------|-------------|
| `fs-runner.sh` | Take a snapshot | Connects to each target over SSH, rsyncs data into the target's ZFS dataset, then takes a ZFS snapshot. Writes Prometheus metrics. |
| `fs-doctor.sh` | Health check | Checks SSH connectivity, source paths, and ZFS datasets. Detects orphaned datasets (targets removed from `targets.yml` with remaining datasets). |
| `fs-retention.sh` | Prune old snapshots | Destroys ZFS snapshots older than the configured KEEP_* limits per class per snapshot type. |
| `fs-db-export.sh` | Export databases | Dumps databases via `docker exec` to an export directory before backup runs, ensuring a consistent snapshot. Runs as root. |
| `fs-install.sh` | Bare-metal installer | Installs fsbackup to `/opt/fsbackup`, creates the `fsbackup` user, configures ZFS delegation, sudoers drop-in, and systemd units. |
| `fs-schedule-apply.sh` | Apply schedule | Writes `OnCalendar=` systemd drop-in overrides from `CLASS*_*_SCHEDULE` variables in `fsbackup.conf`. |

---

## Scripts — manual use (administrative utilities)

These tools are run by hand when needed. They are not wired to any timer.

Repository path: **utils/**

| Filename | Name | Description | Parameters |
|----------|------|-------------|------------|
| `fs-restore.sh` | Restore files | Browse available snapshots and restore files to a local path or push to a remote host over SSH. See the [Restore](#restore) section. | `list --class <class> [--type <type>]`; `restore --class <class> --id <id> [--date <key>\|--latest] --to <path>` |
| `fs-trust-host.sh` | Seed SSH host keys | Adds a host's SSH key to the backup user's `known_hosts`. Run once when adding a new host. | `<hostname>` |
| `fs-target-rename.sh` | Rename a target | Renames (or deletes) a ZFS dataset when a target ID changes in `targets.yml`. | `--class <class> --from <old-id> --to <new-id> --move\|--delete` |

---

## Remote scripts

These scripts are deployed to and run **on the source hosts**, not the backup server.

Repository path: **remote/**

| Filename | Name | Description | Parameters |
|----------|------|-------------|------------|
| `fsbackup_remote_init.sh` | Set up source host | Creates the `backup` user, configures SSH authorized keys, and sets read-only ACLs on paths to be backed up. Run once per new source host. | `--pubkey-file <file>` or `--pubkey <key>`, `--backup-user <user>`, `--allow-path <path>` (repeatable) |
| `fs-prometheus-prebackup.sh` | Prometheus pre-backup snapshot | Calls the Prometheus HTTP API to snapshot its data directory before backup runs. | none |
| `fs-victoriametrics-prebackup.sh` | VictoriaMetrics pre-backup snapshot | Calls the VictoriaMetrics API to snapshot its data directory before backup runs. | none |

---

## S3 cloud export

`s3/fs-export-s3.sh` compresses, encrypts, and uploads snapshots to Amazon S3 for offsite storage. Weekly and monthly snapshots are exported; daily snapshots and class3 are not. Files are encrypted with [age](https://github.com/FiloSottile/age) before upload so S3 never holds readable data. Retention is managed entirely by S3 lifecycle rules — the script never deletes anything.

Called by: `fsbackup-s3-export.timer` (systemd).

### S3 setup

These steps are required once before enabling the timer.

**1. Generate the age keypair**

Run on the backup server:

```bash
age-keygen 2>/dev/null | grep "public key"   # prints the public key
age-keygen -o /tmp/age.key                   # writes the private key file
sudo cp /tmp/age.key.pub /etc/fsbackup/age.pub
sudo chown fsbackup:fsbackup /etc/fsbackup/age.pub
rm /tmp/age.key   # delete private key from server
```

Store the private key in a password manager or print it and keep it somewhere safe — **not on the backup server**. You only need it to decrypt a restored archive.

**2. Create the S3 bucket**

Replace `SUFFIX` with the last 6 digits of your AWS account ID. Run from any machine with admin AWS credentials:

```bash
BUCKET="fsbackup-snapshots-SUFFIX"
REGION="us-west-2"    # or your preferred region

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

**3. Set lifecycle rules**

S3 handles expiration automatically via prefix-based rules. No script ever deletes objects.

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "expire-weekly",
        "Status": "Enabled",
        "Filter": {"Prefix": "weekly/"},
        "Expiration": {"Days": 84}
      },
      {
        "ID": "expire-monthly",
        "Status": "Enabled",
        "Filter": {"Prefix": "monthly/"},
        "Expiration": {"Days": 450}
      },
      {
        "ID": "abort-incomplete-multipart",
        "Status": "Enabled",
        "Filter": {"Prefix": ""},
        "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 3}
      }
    ]
  }'
```

Objects under `annual/` have no expiration rule and are kept indefinitely. The `abort-incomplete-multipart` rule automatically cleans up abandoned upload parts within 3 days.

**4. Create the IAM policy and upload user**

In the AWS Console: IAM → Policies → Create policy → paste this JSON (replace `SUFFIX`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::fsbackup-snapshots-SUFFIX",
        "arn:aws:s3:::fsbackup-snapshots-SUFFIX/*"
      ]
    }
  ]
}
```

Name it `fsbackup-uploader-policy`. Then: IAM → Users → Create user → name `fsbackup-uploader` → attach that policy → Create access key (type: "Application running outside AWS").

**5. Configure credentials on the backup server**

```bash
sudo -u fsbackup aws configure --profile fsbackup
# Enter the key ID and secret from the step above
# Region: us-west-2 (or your region)
# Output format: json
```

Test it:

```bash
sudo -u fsbackup aws s3 ls s3://fsbackup-snapshots-SUFFIX --profile fsbackup
```

**6. Update fsbackup.conf**

Add to `/etc/fsbackup/fsbackup.conf`:

```bash
S3_BUCKET="fsbackup-snapshots-SUFFIX"
S3_SKIP_CLASSES="class3"
```

---

## Daily schedule

All times are approximate; systemd timers use `RandomizedDelaySec` to avoid thundering herd.

| Time | Job |
|------|-----|
| 01:17 | Doctor — class1 |
| 01:40 | DB export — paperless |
| 01:49 | Runner — class1 (daily) |
| 02:05 | Doctor — class2 |
| 02:15 | Runner — class2 (daily) |
| 03:00 | Retention |
| 04:30 | S3 export |

Weekly and monthly runner instances fire on the configured day/date (Monday for weekly, 1st of month for monthly). class3 runs monthly: doctor at 04:15, runner at 04:45 on the 1st.

---

## Prometheus metrics

All metrics are written as textfile collector `.prom` files to `/var/lib/node_exporter/textfile_collector/` and scraped by node_exporter. All metrics are type `gauge` unless noted.

### Snapshot metrics (`fs-runner.sh`)

| Metric | Labels | Description |
|--------|--------|-------------|
| `fsbackup_snapshot_last_success` | `class`, `target` | Unix timestamp of the last successful snapshot |
| `fsbackup_snapshot_last_failure` | `class`, `target` | Unix timestamp of the last failed snapshot attempt |
| `fsbackup_snapshot_bytes` | `class`, `target` | Total size of the ZFS dataset in bytes |
| `fsbackup_snapshot_files_total` | `class`, `target` | Total number of files in the snapshot |
| `fsbackup_snapshot_files_created` | `class`, `target` | Files added compared to the previous snapshot |
| `fsbackup_snapshot_files_deleted` | `class`, `target` | Files removed compared to the previous snapshot |
| `fsbackup_snapshot_transferred_bytes` | `class`, `target` | Bytes actually transferred (the true delta) |
| `fsbackup_runner_target_last_seen` | `class`, `target` | Unix timestamp of the last run attempt, success or failure |
| `fsbackup_runner_target_last_exit_code` | `class`, `target` | rsync exit code of the last run (0 = success) |
| `fsbackup_runner_target_failures_total` | `class`, `target` | Monotonically increasing failure count per target (counter) |
| `fsbackup_runner_success` | `class` | Number of targets that succeeded in the last full class run |
| `fsbackup_runner_failed` | `class` | Number of targets that failed in the last full class run |
| `fsbackup_runner_last_exit_code` | `class` | Overall exit code for the class run (0 = all succeeded, 1 = any failed) |
| `fsbackup_runner_run_scope` | `class` | 1 = full class run, 0 = single-target run |

### Doctor metrics (`fs-doctor.sh`)

| Metric | Labels | Description |
|--------|--------|-------------|
| `fsbackup_orphan_snapshots_total` | — | Count of ZFS datasets belonging to targets no longer in `targets.yml`. Alert if > 0. |
| `fsbackup_doctor_duration_seconds` | `class` | How long the doctor run took, in seconds |

### Retention metrics (`fs-retention.sh`)

| Metric | Labels | Description |
|--------|--------|-------------|
| `fsbackup_retention_last_run_seconds` | — | Unix timestamp of the last retention run |
| `fsbackup_retention_last_exit_code` | — | Exit code of the last retention run (0 = success) |
| `fsbackup_retention_destroyed_total` | — | ZFS snapshots destroyed in this run |
| `fsbackup_retention_kept_total` | — | ZFS snapshots kept (within policy) |
| `fsbackup_retention_failed_total` | — | ZFS snapshots that failed to destroy |
| `fsbackup_retention_duration_seconds` | — | Duration of the retention run in seconds |

### DB export metrics (`fs-db-export.sh`)

| Metric | Labels | Description |
|--------|--------|-------------|
| `fsbackup_db_export_success` | `db`, `engine`, `host` | 1 if export succeeded, 0 if failed |
| `fsbackup_db_export_last_timestamp` | `db`, `engine`, `host` | Unix timestamp of the export run |
| `fsbackup_db_export_size_bytes` | `db`, `engine`, `host` | Size of the compressed export file |

### S3 export metrics (`fs-export-s3.sh`)

| Metric | Labels | Description |
|--------|--------|-------------|
| `fsbackup_s3_last_success` | — | Unix timestamp of the last S3 export run completion |
| `fsbackup_s3_last_exit_code` | — | 0 if all uploads succeeded, 1 if any failed |
| `fsbackup_s3_uploaded_total` | — | Number of archives uploaded in this run |
| `fsbackup_s3_skipped_total` | — | Number of archives skipped (already in S3) |
| `fsbackup_s3_failed_total` | — | Number of archives that failed to upload |
| `fsbackup_s3_bytes_total` | — | Bytes uploaded in this run |
| `fsbackup_s3_duration_seconds` | — | Duration of the S3 export run in seconds |
| `fsbackup_s3_target_last_upload` | `tier`, `class`, `target` | Unix timestamp of the last successful S3 upload for this target |
| `fsbackup_s3_target_last_failure` | `tier`, `class`, `target` | Unix timestamp of the last S3 upload failure for this target |

---

## Restore

Use `utils/fs-restore.sh` directly as the `fsbackup` user. Snapshots are accessible read-only under `<dataset>/.zfs/snapshot/<name>/`.

### Browse available snapshots

```bash
# List snapshot types available for a class
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list --class class1

# List targets under a specific class and type
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list --class class1 --type daily
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list --class class2 --type weekly
```

### Restore to a local path

```bash
# Restore the most recent daily snapshot
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh restore \
  --class class2 --id nginx.data \
  --latest \
  --to /tmp/restore/nginx

# Restore from a specific snapshot
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh restore \
  --class class2 --id ns1.bind.named.conf \
  --date 2026-W09 \
  --to /tmp/restore/bind
```

### Restore directly to a remote host

The script rsyncs the snapshot to `backup@<host>:<path>` over SSH using the same key the runner uses.

```bash
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh restore \
  --class class2 --id ns1.bind.named.conf \
  --latest \
  --to-host ns1 --to-path /tmp/restore-bind
```

### Restore flags reference

| Flag | Required | Description |
|------|----------|-------------|
| `--class` | yes | `class1`, `class2`, `class3` |
| `--id` | yes (restore) | Target name as shown in `list` output |
| `--type` | no | `daily`, `weekly`, or `monthly` (default: daily) |
| `--latest` | one of | Use the most recent available snapshot |
| `--date` | one of | Explicit snapshot key (`2026-03-29`, `2026-W13`, `2026-03`) |
| `--to` | one of | Local destination directory |
| `--to-host` + `--to-path` | one of | Remote host and path (rsync over SSH) |

---

## Restore from S3

S3 archives are stored as encrypted, compressed tar archives. You need:
- The age **private key** (stored off-server — password manager, printed copy, etc.)
- The `age`, `zstd`, and `aws` CLI tools
- AWS credentials with `GetObject` and `ListBucket` permissions

### Browse what's in S3

```bash
aws s3 ls s3://fsbackup-snapshots-SUFFIX/ --profile fsbackup
aws s3 ls s3://fsbackup-snapshots-SUFFIX/weekly/ --recursive --profile fsbackup
aws s3 ls s3://fsbackup-snapshots-SUFFIX/weekly/class1/paperlessngx.db/ --profile fsbackup
```

### Download and decrypt an archive

```bash
aws s3 cp \
  s3://fsbackup-snapshots-SUFFIX/weekly/class1/paperlessngx.db/paperlessngx.db--2026-W09.tar.zst.age \
  /tmp/restore/ \
  --profile fsbackup

age -d -i /path/to/age.key /tmp/restore/paperlessngx.db--2026-W09.tar.zst.age \
  | zstd -d \
  | tar -xf - -C /tmp/restore/paperlessngx.db/
```

### Stream directly without downloading first

```bash
aws s3 cp \
  s3://fsbackup-snapshots-SUFFIX/weekly/class1/paperlessngx.db/paperlessngx.db--2026-W09.tar.zst.age \
  - --profile fsbackup \
  | age -d -i /path/to/age.key \
  | zstd -d \
  | tar -xf - -C /tmp/restore/paperlessngx.db/
```

### S3 archive naming and key structure

```
s3://fsbackup-snapshots-SUFFIX/
  <tier>/
    <class>/
      <target>/
        <target>--<date>.tar.zst.age
```

Examples:
```
weekly/class1/paperlessngx.db/paperlessngx.db--2026-W09.tar.zst.age
monthly/class2/nginx.config/nginx.config--2026-03.tar.zst.age
```

---

## Further reading

- [Installation](docs/installation.md)
- [Adding hosts and targets](docs/adding-hosts-and-targets.md)
- [Operations guide](docs/operations.md)
- [Restore guide](docs/restore.md)
- [Reference](docs/reference.md)

---

## License

MIT — Copyright (c) 2026 Ian Kluhsman
