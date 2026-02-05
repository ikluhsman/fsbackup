# fsbackup – Quick Start

This guide gets a new environment backing up in ~10 minutes.

---

## 1. Clone repository

```bash
git clone <internal-repo-url> fsbackup
cd fsbackup
```

---

## 2. Bootstrap backup host

```bash
sudo ./bin/fsbackup_bootstrap.sh
```

Creates:
- fsbackup user
- SSH keypair
- Snapshot directories
- systemd timers (optional)

---

## 3. Configure targets

Edit:

```bash
/etc/fsbackup/targets.yml
```

Example:

```yaml
class2:
  - id: nginx.config
    host: rp
    source: /etc/nginx
    type: dir
```

---

## 4. Initialize remote hosts

On each source host:

```bash
sudo ./bin/fsbackup_remote_init.sh
```

This:
- Creates backup user
- Installs SSH key
- Applies ACLs (read-only)

---

## 5. Verify with doctor

```bash
sudo -u fsbackup ./bin/fs-doctor.sh --class class2
```

All targets must be OK.

---

## 6. Run snapshot

```bash
sudo -u fsbackup ./bin/fs-runner.sh daily --class class2
```

Snapshots are written under:

```text
/bak/snapshots/class2/daily/
```


## Timers

Example of timers on FS:

NEXT                                     LEFT LAST                              PASSED UNIT                            ACTIVATES
Wed 2026-02-04 10:06:19 MST          3min 31s Wed 2026-02-04 09:36:19 MST    26min ago node-patch-status.timer         node-patch-status.service
Wed 2026-02-04 23:12:48 MST               13h Wed 2026-02-04 10:01:03 MST 1min 44s ago motd-news.timer                 motd-news.service
Wed 2026-02-04 23:41:30 MST               13h Wed 2026-02-04 10:01:03 MST 1min 44s ago apt-daily.timer                 apt-daily.service
Thu 2026-02-05 00:00:00 MST               13h Wed 2026-02-04 00:00:00 MST      10h ago dpkg-db-backup.timer            dpkg-db-backup.service
Thu 2026-02-05 00:00:00 MST               13h -                                      - fsbackup-logrotate-metric.timer fsbackup-logrotate-metric.service
Thu 2026-02-05 00:00:00 MST               13h Wed 2026-02-04 00:00:00 MST      10h ago logrotate.timer                 logrotate.service
Thu 2026-02-05 01:15:29 MST               15h Wed 2026-02-04 01:17:21 MST       8h ago fsbackup-doctor@class1.timer    fsbackup-doctor@class1.service
Thu 2026-02-05 01:42:13 MST               15h Wed 2026-02-04 01:42:21 MST       8h ago fs-db-export@paperlessngx.timer fs-db-export@paperlessngx.service
Thu 2026-02-05 01:51:32 MST               15h Wed 2026-02-04 01:48:49 MST       8h ago fsbackup-runner@class1.timer    fsbackup-runner@class1.service
Thu 2026-02-05 02:05:00 MST               16h Wed 2026-02-04 02:05:09 MST       7h ago fsbackup-doctor@class2.timer    fsbackup-doctor@class2.service
Thu 2026-02-05 02:15:00 MST               16h Wed 2026-02-04 02:15:01 MST       7h ago fsbackup-runner@class2.timer    fsbackup-runner@class2.service
Thu 2026-02-05 02:30:00 MST               16h Wed 2026-02-04 02:30:05 MST       7h ago fsbackup-mirror-daily.timer     fsbackup-mirror-daily.service
Thu 2026-02-05 02:39:08 MST               16h Wed 2026-02-04 00:17:39 MST       9h ago man-db.timer                    man-db.service
Thu 2026-02-05 03:00:00 MST               16h Wed 2026-02-04 03:00:02 MST       7h ago fsbackup-retention.timer        fsbackup-retention.service
Thu 2026-02-05 03:30:00 MST               17h Wed 2026-02-04 03:30:07 MST       6h ago fsbackup-promote.timer          fsbackup-promote.service
Thu 2026-02-05 03:40:00 MST               17h Wed 2026-02-04 03:40:09 MST       6h ago fsbackup-mirror-promote.timer   fsbackup-mirror-promote.service
Thu 2026-02-05 04:00:00 MST               17h Wed 2026-02-04 04:00:01 MST       6h ago fsbackup-mirror-retention.timer fsbackup-mirror-retention.service
Thu 2026-02-05 04:09:20 MST               18h Wed 2026-02-04 00:50:17 MST       9h ago mdcheck_continue.timer          mdcheck_continue.service
Thu 2026-02-05 06:05:07 MST               20h Wed 2026-02-04 06:05:07 MST 3h 57min ago update-notifier-download.timer  update-notifier-download.service
Thu 2026-02-05 06:15:09 MST               20h Wed 2026-02-04 06:15:09 MST 3h 47min ago systemd-tmpfiles-clean.timer    systemd-tmpfiles-clean.service
Thu 2026-02-05 06:38:20 MST               20h Wed 2026-02-04 06:09:47 MST 3h 53min ago apt-daily-upgrade.timer         apt-daily-upgrade.service
Thu 2026-02-05 12:05:12 MST          1 day 2h Wed 2026-02-04 10:01:03 MST 1min 44s ago mdmonitor-oneshot.timer         mdmonitor-oneshot.service
Sun 2026-02-08 03:10:19 MST            3 days Sun 2026-02-01 03:10:08 MST            - e2scrub_all.timer               e2scrub_all.service
Mon 2026-02-09 00:12:44 MST            4 days Mon 2026-02-02 01:04:01 MST            - fstrim.timer                    fstrim.service
Sat 2026-02-14 10:22:56 MST     1 week 3 days Mon 2026-02-02 11:56:21 MST            - update-notifier-motd.timer      update-notifier-motd.service
Sun 2026-03-01 02:22:55 MST    3 weeks 3 days Sun 2026-02-01 01:35:45 MST            - mdcheck_start.timer             mdcheck_start.service
Tue 2027-01-05 03:00:00 MST 10 months 30 days -                                      - fsbackup-annual-promote.timer   fsbackup-annual-promote.service
