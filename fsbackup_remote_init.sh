#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup-remote-init.sh
#
# Prepares a remote host for fsbackup rsync access.
# Safe and idempotent.
#
# Run as root ON THE REMOTE HOST.
# =============================================================================

BACKUP_USER="backup"
BACKUP_GROUP="backup"
NODEEXP_GROUP="nodeexp_txt"
NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"

# --- embedded key placeholder ---
# REPLACE THIS WITH REAL KEY
FSBACKUP_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJwT7RbHgoeGRTQfF/bbdtJJ6+WBfteTH5jYTzZUUcc"

echo "== fsbackup remote init starting =="

# -----------------------------
# User & group sanity
# -----------------------------
getent passwd "$BACKUP_USER" >/dev/null || {
  useradd \
    --system \
    --home /var/lib/fsbackup \
    --create-home \
    --shell /usr/sbin/nologin \
    "$BACKUP_USER"
}

usermod -s /usr/sbin/nologin "$BACKUP_USER"

# -----------------------------
# SSH setup
# -----------------------------
SSH_DIR="/var/lib/fsbackup/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$BACKUP_USER:$BACKUP_GROUP" "$SSH_DIR"

grep -qxF "$FSBACKUP_PUBKEY" "$AUTH_KEYS" 2>/dev/null || {
  echo "$FSBACKUP_PUBKEY" >>"$AUTH_KEYS"
}

chmod 600 "$AUTH_KEYS"
chown "$BACKUP_USER:$BACKUP_GROUP" "$AUTH_KEYS"

# -----------------------------
# node_exporter coexistence
# -----------------------------
getent group "$NODEEXP_GROUP" >/dev/null || groupadd "$NODEEXP_GROUP"

usermod -aG "$NODEEXP_GROUP" "$BACKUP_USER"

mkdir -p "$NODEEXP_DIR"
chown root:"$NODEEXP_GROUP" "$NODEEXP_DIR"
chmod 2775 "$NODEEXP_DIR"

# Verifier (one-liner you asked for)
sudo -u "$BACKUP_USER" test -w "$NODEEXP_DIR" || {
  echo "ERROR: backup cannot write to node_exporter textfile dir"
  exit 1
}

# -----------------------------
# Docker traversal (if exists)
# -----------------------------
if [[ -d /docker ]]; then
  setfacl -m u:"$BACKUP_USER":x /docker
fi

# -----------------------------
# BIND (if exists)
# -----------------------------
if [[ -d /etc/bind ]]; then
  setfacl -m u:"$BACKUP_USER":rx /etc/bind
  [[ -f /etc/bind/rndc.conf ]] && \
    setfacl -m u:"$BACKUP_USER":r /etc/bind/rndc.conf
fi

echo "== fsbackup remote init complete =="

