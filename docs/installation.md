# Installation — fsbackup backup server

This document covers setting up the fsbackup system on the primary backup host.
For adding new source hosts, see [adding-hosts-and-targets.md](adding-hosts-and-targets.md).

---

## Choose your deployment

| | Docker | Bare-metal |
|---|---|---|
| **Recommended** | Yes | For environments without Docker |
| **Scheduler** | supercronic (in container) | supercronic |
| **Scripts run as** | fsbackup user inside container | fsbackup user on host |
| **Config location** | `/etc/fsbackup/` (bind-mounted) | `/etc/fsbackup/` |

**Docker:** follow steps 1–7 below, then continue in [docker.md](docker.md).

**Bare-metal:** follow steps 1–7 below, then continue in the [Bare-metal deployment](#bare-metal-deployment) section.

---

## Common setup (both paths)

### 1. Clone the repository

```bash
git clone https://github.com/fsbackup/fsbackup /home/<user>/fsbackup
```

---

### 2. Run the bootstrap installer

`install.sh` creates the `fsbackup` system user and group, generates the SSH keypair,
creates required directories, installs supercronic, and sets up the node_exporter
textfile collector. It is safe to re-run at any time.

```bash
sudo /home/<user>/fsbackup/install.sh
```

At the end, it will offer to run the web UI setup (`web/install.sh`) automatically.

The SSH public key path is printed at the end — you'll need it when adding remote hosts.

---

### 3. Copy config files

```bash
sudo cp /home/<user>/fsbackup/conf/fsbackup.conf.example /etc/fsbackup/fsbackup.conf
sudo cp /home/<user>/fsbackup/conf/targets.yml.example /etc/fsbackup/targets.yml
sudo cp /home/<user>/fsbackup/conf/fsbackup.crontab /etc/fsbackup/fsbackup.crontab
```

Edit `/etc/fsbackup/fsbackup.conf`:

```bash
SNAPSHOT_ROOT="/backup/snapshots"
SNAPSHOT_MIRROR_ROOT="/backup2/snapshots"
MIRROR_SKIP_CLASSES="class3"
```

`MIRROR_SKIP_CLASSES` is a space-separated list of class names to exclude from mirroring.

---

### 4. Create mirror snapshot directory

If you have a second backup drive, create its snapshot root:

```bash
sudo mkdir -p /backup2/snapshots
sudo chown -R fsbackup:fsbackup /backup2/snapshots
```

---

## Docker deployment

See [docker.md](docker.md) for the full stack compose setup, volume configuration, and first-run steps.

Quick start:

```bash
mkdir -p /docker/stacks/fsbackup
cp /home/<user>/fsbackup/conf/docker-compose.yml.example /docker/stacks/fsbackup/docker-compose.yml
# Edit docker-compose.yml — set image tag, ports, volumes, extra_hosts
cd /docker/stacks/fsbackup
docker compose up -d
```

Trust remote host SSH keys:

```bash
docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

Verify and run first snapshot:

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

---

## Bare-metal deployment

### 8. Install scripts

```bash
sudo mkdir -p /opt/fsbackup
sudo cp -r /home/<user>/fsbackup/bin /opt/fsbackup/bin
sudo cp -r /home/<user>/fsbackup/utils /opt/fsbackup/utils
sudo cp -r /home/<user>/fsbackup/s3 /opt/fsbackup/s3
sudo chmod -R 755 /opt/fsbackup
```

---

### 9. Trust remote host SSH keys

```bash
sudo /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

For local targets, no key trust is needed — rsync accesses paths directly.

---

### 10. Enable the scheduler

The supercronic scheduler and its systemd service unit (`fsbackup-scheduler.service`) are
set up by `web/install.sh` (which `install.sh` offered to run in step 2). If you ran it
and answered yes to the scheduler prompt, enable and start the service:

```bash
sudo systemctl enable --now fsbackup-scheduler.service
```

If you skipped the web UI setup, run `web/install.sh` now and answer yes to the scheduler
prompt, or install supercronic manually and deploy the crontab:

```bash
sudo cp /home/<user>/fsbackup/conf/fsbackup.crontab /etc/fsbackup/fsbackup.crontab
sudo cp /home/<user>/fsbackup/systemd/fsbackup-scheduler.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now fsbackup-scheduler.service
```

---

### 11. Verify and run first snapshot

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
```

All targets should report `OK`. Fix any `FAIL` entries before running the runner.

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```
