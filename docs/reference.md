# Reference

System overview: classes, snapshot structure, retention, promotion, mirror, and offsite.

---

## Data classes

Targets are organized into classes. Each class has its own backup schedule, retention
policy, and offsite strategy.

### class1 — Application data

Frequently changing data: app volumes, databases, personal files.

- **Schedule**: daily at ~01:49
- **Tiers**: daily, weekly, monthly, annual
- **Mirror**: yes (to `/backup2`)
- **Annual**: December monthly snapshot promoted to annual on Jan 5
- **Offsite**: via S3 (planned — see [Offsite](#offsite))

### class2 — Infrastructure config

Slowly changing config: docker stacks, nginx, bind, webmin, etc.

- **Schedule**: daily at ~02:15
- **Tiers**: daily, weekly, monthly (no annual)
- **Mirror**: yes (to `/backup2`)
- **Offsite**: via S3 (planned — see [Offsite](#offsite))

### class3 — Large archives

Large, infrequently changing data: photo libraries, raw camera files.

- **Schedule**: monthly (1st of each month at ~04:45)
- **Tiers**: monthly only (no daily, no weekly, no annual)
- **Mirror**: **no** — excluded via `MIRROR_SKIP_CLASSES=class3` in `fsbackup.conf`
- **Offsite**: M-DISC annually (manual), USB external drive monthly (manual)

---

## Snapshot path structure

```
/backup/snapshots/<tier>/<date>/<class>/<target-id>/
```

| Component | Values |
|---|---|
| `tier` | `daily`, `weekly`, `monthly`, `annual` |
| `date` | `YYYY-MM-DD` (daily), `YYYY-Www` (weekly), `YYYY-MM` (monthly), `YYYY` (annual) |
| `class` | `class1`, `class2`, `class3` |
| `target-id` | as defined in `targets.yml` |

Example: `/backup/snapshots/daily/2026-03-05/class1/mosquitto.data/`

The mirror follows the same structure under `/backup2/snapshots/`.

---

## Retention policy

### Primary (`/backup/snapshots`)

| Tier | Kept |
|---|---|
| daily | 14 days |
| weekly | 8 weeks |
| monthly | 12 months |
| annual | indefinite (never pruned by retention script) |

Retention runs daily at ~03:00 via `fsbackup-retention.timer`.

### Mirror (`/backup2/snapshots`)

| Tier | Kept |
|---|---|
| daily | 14 days |
| weekly | 12 weeks |
| monthly | 24 months |

Mirror retention runs daily at ~04:00 via `fsbackup-mirror-retention.timer`.
Mirror keeps longer weekly/monthly history than primary due to available space.

---

## Promotion

Promotion creates hardlinked copies of daily snapshots into higher tiers.
Hardlinks mean promoted snapshots share blocks with the daily source — no extra disk
space for unchanged files.

| Event | Action | Condition |
|---|---|---|
| Daily → weekly | Promote today's daily to `weekly/YYYY-Www/` | Runs on Monday (DOW=1) |
| Daily → monthly | Promote today's daily to `monthly/YYYY-MM/` | Runs on 1st of month |
| Monthly Dec → annual | Promote December monthly to `annual/YYYY/` | Runs Jan 5 each year |

Only `class1` is promoted to annual. `class2` and `class3` have no annual tier.

Promotion only proceeds if the source daily snapshot has a clean exit code
(`.fsbackup_class_exit_code` = 0). A failed daily is not promoted.

Annual snapshots are made read-only (`chmod -R u-w`) immediately after creation.

---

## Mirror logic

The mirror (`fs-mirror.sh`) runs in two modes:

### daily mode

Copies today's daily snapshot from primary to mirror, skipping any classes listed in
`MIRROR_SKIP_CLASSES`. Runs at ~02:30 after the runner completes.

### promote mode

Syncs the entire `weekly/` and `monthly/` trees from primary to mirror, with per-class
excludes for any classes in `MIRROR_SKIP_CLASSES`. Runs at ~03:40 after promotion.

Mirror uses `rsync -a --ignore-existing` so it never overwrites data already on the mirror.

Classes in `MIRROR_SKIP_CLASSES` (currently `class3`) are never mirrored to `/backup2`.

---

## Offsite strategy

### class1 and class2

S3 offsite is planned but not yet implemented. The existing `fs-export-s3.sh` script is
broken and needs a complete rewrite before use.

_This section will be updated when the S3 export system is designed and implemented._

### class3 — photos and large archives

class3 is not mirrored to `/backup2`. Offsite copies are made manually:

| Frequency | Medium | Process |
|---|---|---|
| Monthly | USB external drive | Manual copy from `/backup/snapshots/monthly/YYYY-MM/class3/` |
| Annual | M-DISC (archival optical disc) | Manual burn from the December monthly snapshot |

M-DISC is suitable for class3 because the data is large, changes slowly, and benefits
from media that does not degrade over time. The annual burn corresponds to the same
snapshot that would be promoted to annual for class1.

---

## Timer schedule

All times approximate. Timers use `RandomizedDelaySec` to avoid thundering herd.

| Time | Unit | Action |
|---|---|---|
| 01:17 | `fsbackup-doctor@class1` | SSH/path health check, orphan scan |
| 01:40 | `fs-db-export@paperlessngx` | DB dump to export dir |
| 01:49 | `fsbackup-runner@class1` | Daily snapshot — class1 |
| 02:05 | `fsbackup-doctor@class2` | SSH/path health check |
| 02:15 | `fsbackup-runner@class2` | Daily snapshot — class2 |
| 02:30 | `fsbackup-mirror-daily` | Mirror today's daily (class1 + class2) |
| 03:00 | `fsbackup-retention` | Prune primary snapshots |
| 03:30 | `fsbackup-promote` | Promote daily → weekly/monthly |
| 03:40 | `fsbackup-mirror-promote` | Mirror weekly + monthly tiers |
| 04:00 | `fsbackup-mirror-retention` | Prune mirror snapshots |
| 04:15 (1st) | `fsbackup-doctor@class3` | Health check (runs 1st of month) |
| 04:45 (1st) | `fsbackup-runner@class3` | Monthly snapshot — class3 (runs 1st of month) |
| Jan 5, 03:00 | `fsbackup-annual-promote` | Promote Dec monthly → annual (class1 only) |

---

## Key paths

| Path | Purpose |
|---|---|
| `/opt/fsbackup/` | Repository — all scripts, configs, systemd units |
| `/etc/fsbackup/fsbackup.conf` | Runtime config (roots, skip classes) |
| `/etc/fsbackup/targets.yml` | Target definitions |
| `/var/lib/fsbackup/` | fsbackup user home |
| `/var/lib/fsbackup/.ssh/` | SSH keys for fsbackup user |
| `/var/lib/fsbackup/.ssh/id_ed25519_backup` | Private key used to pull from remotes |
| `/var/lib/fsbackup/log/` | All log files |
| `/backup/snapshots/` | Primary snapshot root |
| `/backup2/snapshots/` | Mirror snapshot root |
| `/var/lib/node_exporter/textfile_collector/` | Prometheus metrics output |

---

## Prometheus metrics

| Metric | Description |
|---|---|
| `fsbackup_snapshot_last_success{class,target}` | Unix timestamp of last successful snapshot |
| `fsbackup_snapshot_bytes{class,target}` | Bytes in last successful snapshot |
| `fsbackup_runner_target_last_exit_code{class,target}` | Exit code of last run |
| `fsbackup_runner_target_failures_total{class,target}` | Cumulative failure count |
| `fsbackup_runner_success{class}` | Targets succeeded in last run |
| `fsbackup_runner_failed{class}` | Targets failed in last run |
| `fsbackup_orphan_snapshots_total{root}` | Orphaned snapshot directories detected |
| `fsbackup_annual_immutable{root}` | 1 if annual snapshots are read-only |
| `fsbackup_mirror_last_success{mode}` | Timestamp of last mirror run |
| `fsbackup_mirror_last_exit_code{mode}` | Exit code of last mirror run |
| `fsbackup_mirror_bytes_total{mode}` | Bytes in mirrored scope |
| `fsbackup_retention_last_run_seconds` | Timestamp of last retention run |
| `fsbackup_promote_weekly_classes_promoted` | Classes promoted to weekly last run |
| `fsbackup_promote_monthly_classes_promoted` | Classes promoted to monthly last run |
| `fsbackup_annual_promote_success{year}` | 1 if annual promote succeeded |
| `fsbackup_doctor_duration_seconds{class}` | Doctor run duration |
| `fsbackup_ssh_host_key_present{host,fingerprint}` | 1 if SSH host key is trusted |
