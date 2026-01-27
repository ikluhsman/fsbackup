#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup_remote_init.sh
#
# Prepares a remote host for fsbackup rsync pulls.
# Safe and idempotent.
#
# Fixes:
#  - nologin shell breaking rsync
#  - SSH key installation
#  - node_exporter textfile permissions
#  - noisy shells corrupting rsync protocol
#
# =============================================================================

BACKUP_USER="backup"
BACKUP_GROUP="backup"
BACKUP_HOME="/home/backup"
BACKUP_SHELL="/bin/bash"

NODEEXP_GROUP="nodeexp_txt"
NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"

SSH_DIR="${BACKUP_HOME}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

PROM_FILE="${NODEEXP_DIR}/fsbackup_remote_init.prom"

# ---------------------------------------------------------------------
# FAKE KEY — replace with real fsbackup public key
# ---------------------------------------------------------------------
FSBACKUP_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYREPLACEME fsbackup@fs"

# ---------------------------------------------------------------------
# Sanity
# ---------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Must run as root"; exit 1; }

# ---------------------------------------------------------------------
# Ensure groups
# ---------------------------------------------------------------------
getent group "$BACKUP_GROUP" >/dev/null || groupadd "$BACKUP_GROUP"
getent group "$NODEEXP_GROUP" >/dev/null || groupadd "$NODEEXP_GROUP"

# ---------------------------------------------------------------------
# Ensure backup user
# ---------------------------------------------------------------------
if ! id "$BACKUP_USER" >/dev/null 2>&1; then
  useradd \
    --home "$BACKUP_HOME" \
    --create-home \
    --shell "$BACKUP_SHELL" \
    --gid "$BACKUP_GROUP" \
    "$BACKUP_USER"
fi

# Force correct shell (CRITICAL)
usermod -s "$BACKUP_SHELL" "$BACKUP_USER"

# ---------------------------------------------------------------------
# SSH setup
# ---------------------------------------------------------------------
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$BACKUP_USER:$BACKUP_GROUP" "$SSH_DIR"

touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
chown "$BACKUP_USER:$BACKUP_GROUP" "$AUTHORIZED_KEYS"

if ! grep -q "fsbackup@fs" "$AUTHORIZED_KEYS"; then
  echo "$FSBACKUP_PUBKEY" >>"$AUTHORIZED_KEYS"
fi

# ---------------------------------------------------------------------
# Silence non-interactive shells (REQUIRED FOR RSYNC)
# ---------------------------------------------------------------------
BASHRC="${BACKUP_HOME}/.bashrc"

if [[ ! -f "$BASHRC" ]] || ! grep -q "non-interactive guard" "$BASHRC"; then
  cat >>"$BASHRC" <<'EOF'

# --- fsbackup non-interactive guard ---
# Prevent rsync protocol corruption
[[ $- != *i* ]] && return
# --- end fsbackup guard ---
EOF
fi

chown "$BACKUP_USER:$BACKUP_GROUP" "$BASHRC"
chmod 644 "$BASHRC"

# ---------------------------------------------------------------------
# node_exporter textfile permissions (do NOT break patchcheck)
# ---------------------------------------------------------------------
mkdir -p "$NODEEXP_DIR"
chown root:"$NODEEXP_GROUP" "$NODEEXP_DIR"
chmod 2775 "$NODEEXP_DIR"

usermod -aG "$NODEEXP_GROUP" "$BACKUP_USER"

# ---------------------------------------------------------------------
# Write Prometheus metric
# ---------------------------------------------------------------------
cat >"$PROM_FILE" <<EOF
# HELP fsbackup_remote_init_status Remote init status (0=success)
# TYPE fsbackup_remote_init_status gauge
fsbackup_remote_init_status{host="$(hostname -s)"} 0
EOF

chown root:"$NODEEXP_GROUP" "$PROM_FILE"
chmod 664 "$PROM_FILE"

# ---------------------------------------------------------------------
# Verification (one-liners)
# ---------------------------------------------------------------------
su - "$BACKUP_USER" -c 'echo ssh-shell-ok' >/dev/null
su - "$BACKUP_USER" -c 'touch /var/lib/node_exporter/textfile_collector/.fsbackup_test' >/dev/null
rm -f /var/lib/node_exporter/textfile_collector/.fsbackup_test

echo "fsbackup remote init complete on $(hostname -s)"

