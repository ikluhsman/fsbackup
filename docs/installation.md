# Installation — fsbackup backup server

This document covers setting up the fsbackup system on the primary backup host (`fs`).
For adding new source hosts, see [adding-hosts-and-targets.md](adding-hosts-and-targets.md).

---

## Prerequisites

- Ubuntu/Debian Linux
- Dedicated backup drive(s) mounted (e.g. `/backup`, `/backup2`)
- Packages: `rsync`, `ssh`, `acl`, `yq`, `jq`
- `node_exporter` with textfile collector (optional, for metrics)

```bash
apt install rsync openssh-client acl yq jq
```

---

## 1. Clone the repository

```bash
git clone <repo-url> /opt/fsbackup
cd /opt/fsbackup
```

All scripts run directly from `/opt/fsbackup/bin/`. Nothing is copied to `/usr/local/sbin`.

---

## 2. Create the fsbackup system user

```bash
useradd -r -m -d /var/lib/fsbackup -s /bin/bash fsbackup
```

This user runs all backup scripts via systemd. It must own its home directory and SSH key.

---

## 3. Generate the backup SSH keypair

The `fsbackup` user on this host pulls from remote hosts using the `backup` user over SSH.
The keypair lives in the fsbackup home directory.

```bash
sudo -u fsbackup ssh-keygen -t ed25519 -f /var/lib/fsbackup/.ssh/id_ed25519_backup -N ""
```

The public key (`id_ed25519_backup.pub`) is what gets installed on each remote source host.
See [adding-hosts-and-targets.md](adding-hosts-and-targets.md) for that process.

---

## 4. Create the config directory

```bash
mkdir -p /etc/fsbackup/db
cp /opt/fsbackup/conf/fsbackup.conf.example /etc/fsbackup/fsbackup.conf
cp /opt/fsbackup/conf/targets.yml /etc/fsbackup/targets.yml
```

Edit `/etc/fsbackup/fsbackup.conf`:

```bash
SNAPSHOT_ROOT="/backup/snapshots"
SNAPSHOT_MIRROR_ROOT="/backup2/snapshots"
MIRROR_SKIP_CLASSES="class3"
```

`MIRROR_SKIP_CLASSES` is a space-separated list of class names to exclude from mirroring.

---

## 5. Create snapshot directories

```bash
mkdir -p /backup/snapshots/{daily,weekly,monthly,annual}
mkdir -p /backup2/snapshots/{daily,weekly,monthly,annual}
chown -R fsbackup:fsbackup /backup/snapshots
chown -R fsbackup:fsbackup /backup2/snapshots
```

---

## 6. Create log and lock directories

```bash
mkdir -p /var/lib/fsbackup/log
chown -R fsbackup:fsbackup /var/lib/fsbackup
```

---

## 7. Set up node_exporter textfile collector (optional)

If you're running Prometheus node_exporter with the textfile collector:

```bash
groupadd nodeexp_txt
usermod -aG nodeexp_txt fsbackup
usermod -aG nodeexp_txt node_exporter   # or whatever user runs node_exporter

mkdir -p /var/lib/node_exporter/textfile_collector
chown root:nodeexp_txt /var/lib/node_exporter/textfile_collector
chmod 2775 /var/lib/node_exporter/textfile_collector
```

---

## 8. Deploy systemd units

The `systemd/` directory in the repo is the source of truth for all unit files.

```bash
sudo cp /opt/fsbackup/systemd/*.service /opt/fsbackup/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

Enable and start timers:

```bash
sudo systemctl enable --now \
  fsbackup-doctor@class1.timer \
  fsbackup-runner@class1.timer \
  fsbackup-doctor@class2.timer \
  fsbackup-runner@class2.timer \
  fsbackup-doctor@class3.timer \
  fsbackup-runner@class3.timer \
  fsbackup-promote.timer \
  fsbackup-mirror-daily.timer \
  fsbackup-mirror-promote.timer \
  fsbackup-retention.timer \
  fsbackup-mirror-retention.timer \
  fsbackup-annual-promote.timer
```

---

## 9. Trust the local host SSH key

For local (`host: fs`) targets, rsync runs directly without SSH. No key trust needed.

For any remote hosts, see [adding-hosts-and-targets.md](adding-hosts-and-targets.md).

---

## 10. Verify

Run the doctor against each class to confirm all targets are reachable:

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class3
```

All targets should report `OK`. Fix any `FAIL` entries before running the runner.

---

## 11. Run a first snapshot

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```
