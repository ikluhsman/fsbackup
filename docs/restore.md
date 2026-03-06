# Restoring from a Snapshot

Restores are performed manually using `utils/fs-restore.sh`. It can restore to a local
path on the backup server or push directly to a remote host over SSH.

> Restores use the same `backup` SSH user that pulls data. The backup user must have
> write access to the destination path on the remote host for remote restores.

---

## Discovering available snapshots

### List available date keys for a tier

```bash
sudo /opt/fsbackup/utils/fs-restore.sh list --type daily
sudo /opt/fsbackup/utils/fs-restore.sh list --type weekly
sudo /opt/fsbackup/utils/fs-restore.sh list --type monthly
```

Output shows available date keys (e.g. `2026-03-05`, `2026-W10`, `2026-03`).

### List classes within a date key

```bash
sudo /opt/fsbackup/utils/fs-restore.sh list --type daily --date 2026-03-05
```

### List targets within a class

```bash
sudo /opt/fsbackup/utils/fs-restore.sh list --type daily --class class1 --date 2026-03-05
```

---

## Restoring to a local path

Restores the snapshot to a directory on the backup server. Useful for inspecting contents
or staging before pushing to a host.

```bash
sudo /opt/fsbackup/utils/fs-restore.sh restore \
  --type daily \
  --class class2 \
  --id rp.nginx.config \
  --latest \
  --to /tmp/restore-nginx
```

Use `--date <key>` to restore a specific snapshot instead of `--latest`:

```bash
sudo /opt/fsbackup/utils/fs-restore.sh restore \
  --type daily \
  --class class2 \
  --id rp.nginx.config \
  --date 2026-02-20 \
  --to /tmp/restore-nginx
```

The snapshot contents are rsynced into `--to`. The destination is created if it does
not exist.

---

## Restoring directly to a remote host

Pushes the snapshot to a path on a remote host over SSH. The `backup` user is used for
the SSH connection, so it must have write permission to `--to-path` on the target host.

```bash
sudo /opt/fsbackup/utils/fs-restore.sh restore \
  --type daily \
  --class class2 \
  --id ns1.bind.named.conf \
  --date 2026-01-29 \
  --to-host ns1 \
  --to-path /tmp/restore-bind
```

This restores to `/tmp/restore-bind` on `ns1`. Always restore to a staging path first,
verify the contents, then move into place as root.

---

## Restore workflow (recommended)

1. **Identify** the snapshot to restore:
   ```bash
   sudo /opt/fsbackup/utils/fs-restore.sh list --type daily --class class1
   ```

2. **Stage** the restore locally or to `/tmp` on the target host:
   ```bash
   sudo /opt/fsbackup/utils/fs-restore.sh restore \
     --type daily --class class1 --id mosquitto.data \
     --latest --to /tmp/restore-mosquitto
   ```

3. **Verify** the contents look correct before touching production paths.

4. **Move into place** as appropriate (stop service, swap directory, restart service).

---

## Restoring from the mirror

The mirror at `/backup2/snapshots` follows the same directory structure as the primary.
`fs-restore.sh` always restores from the primary (`/backup/snapshots`). To restore from
the mirror, either:

- Temporarily update `SNAPSHOT_ROOT` in `/etc/fsbackup/fsbackup.conf` to point at
  `/backup2/snapshots`, then run the restore script.
- Or copy the snapshot directory from the mirror to primary first, then restore normally.

---

## Restoring class3 (photos)

class3 snapshots are monthly and live only on the primary:

```bash
sudo /opt/fsbackup/utils/fs-restore.sh list --type monthly --class class3

sudo /opt/fsbackup/utils/fs-restore.sh restore \
  --type monthly \
  --class class3 \
  --id pictures.digital_cameras \
  --latest \
  --to /tmp/restore-photos
```

For M-DISC or USB offsite restores, mount the media and copy directly — those are plain
directory trees and do not need the restore script.
