# Operations

Day-to-day management: checking health, running jobs manually, managing orphans, and
verifying the mirror.

---

## Checking system health

### Doctor

The doctor checks SSH reachability and source path existence for all targets in a class.
It also scans for orphaned snapshots and verifies annual snapshot immutability.

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class3
```

Output:

```
fsbackup doctor
  Class:  class2

TARGET                       STAT   DETAIL
---------------------------- ------ ------------------------------
apache.config                OK     local path exists
rp.nginx.config              OK     ssh+path OK
weewx.config                 OK     ssh+path OK

Doctor summary
  OK:    3
  WARN:  0
  FAIL:  0
```

Any `FAIL` must be resolved before the runner will succeed for that target.

### Logs

```bash
# Main backup log (runner + promote + retention all write here)
tail -f /var/lib/fsbackup/log/backup.log

# Mirror log
tail -f /var/lib/fsbackup/log/mirror.log

# Annual promote log
tail -f /var/lib/fsbackup/log/annual-promote.log

# Orphan log (appended by doctor)
cat /var/lib/fsbackup/log/fs-orphans.log
```

### Systemd unit status

```bash
systemctl status fsbackup-runner@class1.service
systemctl status fsbackup-mirror-daily.service
journalctl -u fsbackup-runner@class1.service --since today
```

---

## Running jobs manually

### Dry-run a snapshot (safe, no changes)

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
```

### Run a snapshot for real

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

### Run a single target only

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --target mosquitto.data
```

### Replace an existing snapshot (re-sync over it)

By default the runner uses `--ignore-existing` to avoid re-transferring unchanged data.
To force a full re-sync of an existing snapshot:

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 \
  --target mosquitto.data --replace-existing
```

### Run promotion manually

```bash
sudo /opt/fsbackup/bin/fs-promote.sh
```

Promotion only acts on `DOW=1` (Monday) for weekly and `DOM=01` for monthly. To test
outside those days the script will run but skip promotion — check the log.

### Run annual promotion manually

```bash
sudo /opt/fsbackup/bin/fs-annual-promote.sh --dry-run
sudo /opt/fsbackup/bin/fs-annual-promote.sh
# or for a specific year:
sudo /opt/fsbackup/bin/fs-annual-promote.sh --year 2025
```

### Run retention manually

```bash
sudo /opt/fsbackup/bin/fs-retention.sh
sudo /opt/fsbackup/bin/fs-mirror-retention.sh
```

### Run mirror manually

```bash
sudo /opt/fsbackup/bin/fs-mirror.sh daily
sudo /opt/fsbackup/bin/fs-mirror.sh promote
```

---

## Orphan snapshots

An orphan is a snapshot directory for a target that no longer exists in `targets.yml`.
This happens after removing a target.

### Detecting orphans

The doctor detects orphans on every run and:
- Appends entries to `/var/lib/fsbackup/log/fs-orphans.log`
- Writes a Prometheus metric: `fsbackup_orphan_snapshots_total{root="primary|mirror"}`

View current orphans:

```bash
cat /var/lib/fsbackup/log/fs-orphans.log
```

Each line shows: `root= tier= date= class= orphan=<target-id>`

### Removing orphans

Orphans are never removed automatically. To remove them manually:

```bash
# Inspect first
sudo find /backup/snapshots -type d -name "<target-id>"

# Remove from primary
sudo find /backup/snapshots -type d -name "<target-id>" -exec rm -rf {} +

# Remove from mirror
sudo find /backup2/snapshots -type d -name "<target-id>" -exec rm -rf {} +
```

After removal, run the doctor again to confirm the orphan count drops to zero.

---

## Mirror health

### Check mirror metrics

If using Prometheus/Grafana, check:
- `fsbackup_mirror_last_exit_code{mode="daily"}` — 0 = success
- `fsbackup_mirror_last_exit_code{mode="promote"}` — 0 = success
- `fsbackup_mirror_last_success` — timestamp of last successful run

### Check mirror log

```bash
tail -100 /var/lib/fsbackup/log/mirror.log
```

### Verify mirror contents

```bash
# Compare primary vs mirror for a specific date/class
diff -rq \
  /backup/snapshots/daily/$(date +%F)/class1 \
  /backup2/snapshots/daily/$(date +%F)/class1
```

### Manual mirror check for annual snapshots

```bash
sudo /opt/fsbackup/utils/fs-annual-mirror-check.sh
```

---

## Annual snapshot immutability

Annual snapshots are made read-only after creation (`chmod -R u-w`). The doctor verifies
this on every run and writes `fsbackup_annual_immutable{root="primary|mirror"}`.

If an annual snapshot is accidentally made writable, the doctor will log it to
`/var/lib/fsbackup/log/fs-immutable.log`.

To re-lock:

```bash
sudo chmod -R u-w /backup/snapshots/annual
sudo chmod -R u-w /backup2/snapshots/annual
```

---

## Re-running after a failure

If a target fails mid-run, the next scheduled run will retry it. The failure counter is
tracked in the Prometheus metric `fsbackup_runner_target_failures_total`.

To re-run immediately for a specific target:

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --target <id>
```
