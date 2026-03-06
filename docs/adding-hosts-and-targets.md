# Adding Hosts and Targets

This document covers adding new source hosts and backup targets to fsbackup.

---

## targets.yml format

All targets are defined in `/etc/fsbackup/targets.yml`, organized by class.

```yaml
class1:
  - id: myapp.data          # unique identifier — used as snapshot directory name
    host: myhost            # hostname (SSH alias) or "fs" for local
    source: /path/to/data   # absolute path on the source host
    type: dir               # optional; "dir" is the default and only current type
    rsync_opts: "--exclude=somedir --no-perms"  # optional rsync flags
```

### Field reference

| Field | Required | Description |
|---|---|---|
| `id` | yes | Unique identifier. Used as the snapshot directory name. Use dots as separators (e.g. `host.service.data`). |
| `host` | yes | Hostname of the source. Use `fs` for the local backup server. Must resolve via SSH config or DNS. |
| `source` | yes | Absolute path on the source host to back up. |
| `type` | no | Always `dir`. Kept for forward compatibility. |
| `rsync_opts` | no | Extra rsync flags appended to the base command. Excludes are relative to `source`, not the root of the host. |

### rsync_opts exclude paths

Excludes are **relative to `source`**, not the remote root. For example:

```yaml
- id: nginx.data
  host: denhpsvr1
  source: /docker/volumes/nginx_data
  rsync_opts: "--exclude=_data/nginx/modules --exclude=_data/certbot"
```

Here `_data/certbot` means `/docker/volumes/nginx_data/_data/certbot` on the source.

---

## Adding a local target

Local targets are paths on the backup server (`host: fs`) itself. No SSH is involved —
rsync copies directly from the local filesystem.

1. Add the target entry to `/etc/fsbackup/targets.yml` under the appropriate class:

```yaml
class2:
  - id: myapp.config
    host: fs
    source: /etc/myapp
    type: dir
```

2. Verify the path exists and doctor passes:

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
```

---

## Adding a new remote host

When a host is new (or has been rebuilt), two things need to happen: the backup server must
trust the host's SSH key, and the source host must have the `backup` user installed with
the correct authorized key.

### Step 1 — Trust the host's SSH key (on the backup server)

If the host is new:

```bash
sudo /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

If the host was **rebuilt** and has a new SSH host key, remove the stale entry first:

```bash
sudo -u fsbackup ssh-keygen -R <hostname> -f /var/lib/fsbackup/.ssh/known_hosts
sudo /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

`fs-trust-host.sh` will print the fingerprint of the trusted key. Verify it matches the
host before proceeding.

### Step 2 — Initialize the remote host (run on the source host)

Copy the init script and public key to the remote host, then run it as root:

```bash
# From the backup server:
scp /opt/fsbackup/remote/fsbackup_remote_init.sh <hostname>:/tmp/
scp /var/lib/fsbackup/.ssh/id_ed25519_backup.pub <hostname>:/tmp/

# Then on the remote host:
sudo /tmp/fsbackup_remote_init.sh \
  --pubkey-file /tmp/id_ed25519_backup.pub \
  --allow-path /path/to/backup1 \
  --allow-path /path/to/backup2
```

`--allow-path` can be repeated for each path that needs backing up. It grants the `backup`
user read access via ACL, walking parent directories to ensure traverse permission.

The script will print `VERIFY: remote init OK` if everything is set up correctly.

### Step 3 — Verify from the backup server

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
```

The new host's targets should show `OK  ssh+path OK`.

---

## Adding a remote target to an existing host

If the host is already initialized (backup user + key installed), you only need to:

1. Grant the `backup` user read access to the new path on the source host:

```bash
# On the source host:
sudo setfacl -m u:backup:rx /path/to/newdata
# If parent dirs are restrictive:
sudo setfacl -m u:backup:x /parent/dir
```

Or re-run `fsbackup_remote_init.sh` with the new `--allow-path` — it is idempotent:

```bash
sudo /tmp/fsbackup_remote_init.sh \
  --pubkey-file /tmp/id_ed25519_backup.pub \
  --allow-path /existing/path \
  --allow-path /new/path
```

2. Add the target to `/etc/fsbackup/targets.yml`.

3. Verify:

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class <class>
```

---

## Removing a target

1. Remove the entry from `/etc/fsbackup/targets.yml`.
2. The doctor will stop checking it immediately.
3. Existing snapshots become orphans — see [operations.md](operations.md) for how to
   detect and remove them.
4. Optionally revoke the `backup` user's ACL on the source host:

```bash
sudo setfacl -x u:backup /path/to/olddata
```
