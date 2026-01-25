# fsbackup

## Requirements

apt install yq acl

## Bootstrap installer

server_install.sh

# =============================================================================
# fsbackup-bootstrap.sh
#
# Idempotent bootstrap for FS backup node.
# Safe to run multiple times to restore known-good state.
#
# Usage:
#   fsbackup-bootstrap.sh \
#     --bak-root /bak \
#     --tmp-dir /bak/tmp \
#     --snapshot-dir /bak/snapshots
#
# =============================================================================

This sets up the FS backup node back to defaults and ensures a sane environment.

Safe to re-run at any time (idempotent)
Explicit ownership and permissions (no “best effort”)
Parameterized temp + snapshot roots
Creates and validates fsbackup user
Generates SSH key only if missing
Emits a clear operator note at the end
Fails fast if something fundamental is wrong


## Paths

Configuration

/etc/fsbackup/targets.yml - targets
/etc/fsbackup/fsbackup.env - non-secret defaults
/etc/fsbackup/credentials.env

Libraries

/usr/local/lib/fsbackup/fs-exporter.sh

Executables

/usr/local/sbin/fs-runner.sh
/usr/local/sbin/fs-snapshot.sh
/usr/local/sbin/fs-prune.sh
/usr/local/sbin/fs-export-s3.sh

State

/var/lib/fsbackup/.ssh/id_ed25519_backup
/var/lib/fsbackup/.ssh/id_ed25519_backup.pub
/var/lib/fsbackup/.ssh/config
/var/lib/fsbackup/log
/var/lib/fsbackup/manifests/

/bak/tmp

```

## Create user on the backup server



## Set folder permissions, ensure paths exist

### Create dirs

```
# Configuration
mkdir -p /etc/fsbackup

# Libraries
mkdir -p /usr/local/lib/fsbackup

# Executables (usually already exist, mkdir is harmless)
mkdir -p /usr/local/sbin

# State
mkdir -p /var/lib/fsbackup/.ssh
mkdir -p /var/lib/fsbackup/log
mkdir -p /var/lib/fsbackup/manifests

# Backup temp area (on data volume)
mkdir -p /bak/tmp
```

### Change ownership

```
chown root:fsbackup /etc/fsbackup
chown -R root:root /usr/local/lib/fsbackup
chown root:root /usr/local/sbin/fs-*.sh
chown -R fsbackup:fsbackup /var/lib/fsbackup
chown -R fsbackup:fsbackup /bak/tmp
```

### Permissions

```
chmod 750 /etc/fsbackup

# targets.yml (readable by fsbackup)
chmod 640 /etc/fsbackup/targets.yml

# non-secret defaults
chmod 640 /etc/fsbackup/fsbackup.env

# credentials (secrets)
chmod 600 /etc/fsbackup/credentials.env

# Libraries
chmod 755 /usr/local/lib/fsbackup
chmod 644 /usr/local/lib/fsbackup/fs-exporter.sh

# Executables
chmod 755 /usr/local/sbin/fs-runner.sh
chmod 755 /usr/local/sbin/fs-snapshot.sh
chmod 755 /usr/local/sbin/fs-prune.sh
chmod 755 /usr/local/sbin/fs-export-s3.sh

# State dirs
chmod 700 /var/lib/fsbackup
chmod 700 /var/lib/fsbackup/.ssh
chmod 750 /var/lib/fsbackup/log
chmod 750 /var/lib/fsbackup/manifests

# SSH Keys
chmod 600 /var/lib/fsbackup/.ssh/id_ed25519_backup
chmod 644 /var/lib/fsbackup/.ssh/id_ed25519_backup.pub
chmod 600 /var/lib/fsbackup/.ssh/config

# Backup Temp Dir
chmod 750 /bak/tmp

# Exporter metrics collector text file
chown fsbackup:fsbackup /var/lib/node_exporter/textfile_collector
chmod 755 /var/lib/node_exporter/textfile_collector
```

## Verify

```
# As fsbackup, verify write access
sudo -u fsbackup touch /var/lib/fsbackup/log/test.log
sudo -u fsbackup touch /bak/tmp/test.tmp
sudo -u fsbackup touch /var/lib/node_exporter/textfile_collector/test.prom

# Verify scripts are executable
ls -l /usr/local/sbin/fs-*.sh

# Verify secrets are locked down
ls -l /etc/fsbackup/credentials.env
```


## Creating the server key

```
sudo -u fsbackup ssh-keygen \
  -t ed25519 \
  -f /var/lib/fsbackup/.ssh/id_ed25519_backup \
  -C "fs-backup@$(hostname)"
```

Only recreate the key if something has been compromised, or if a refresh is needed. If you do this you will need to change the public key on all remote backup targets.

## Install backup user and SSH keys on target hosts

1. Create backup user and install public key on each host

Create a matching backup user
`useradd -r -s /bin/bash backup`

2. Install FS’s public key

```
mkdir -p /home/backup/.ssh
chown -R backup:backup /home/backup/.ssh
chmod 700 /home/backup/.ssh
touch /home/backup/.ssh/authorized_keys
chmod 600 /home/backup/.ssh/authorized_keys
```

`nano /home/backup/.ssh/authorized_keys`

```
from="172.30.3.130",
no-agent-forwarding,
no-port-forwarding,
no-pty,
no-X11-forwarding
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
```

3. Set ACL permissions for targets that backup user cannot read:

Example:

```
setfacl -R -m u:backup:rX /etc/headscale
getfacl /etc/headscale
```

You should see something like:
user:backup:r-x

Note you may need to install the 'acl' package on raspberry pi or otherwise.
