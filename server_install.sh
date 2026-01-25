#!/usr/bin/env bash
set -euo pipefail

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

# -----------------------------
# Defaults (can be overridden)
# -----------------------------
BAK_ROOT="/bak"
TMP_DIR=""
SNAPSHOT_DIR=""

FSBACKUP_USER="fsbackup"
FSBACKUP_GROUP="fsbackup"
SSH_KEY_NAME="id_ed25519_backup"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"

# -----------------------------
# Argument parsing
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bak-root)      BAK_ROOT="$2"; shift 2 ;;
    --tmp-dir)       TMP_DIR="$2"; shift 2 ;;
    --snapshot-dir)  SNAPSHOT_DIR="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Derive defaults if not explicitly set
TMP_DIR="${TMP_DIR:-${BAK_ROOT}/tmp}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${BAK_ROOT}/snapshots}"

# -----------------------------
# Sanity checks
# -----------------------------
[[ $EUID -eq 0 ]] || { echo "Must be run as root"; exit 1; }
mountpoint -q "$BAK_ROOT" || { echo "ERROR: $BAK_ROOT is not mounted"; exit 1; }

# -----------------------------
# Ensure fsbackup user & group
# -----------------------------
if ! getent group "$FSBACKUP_GROUP" >/dev/null; then
  groupadd "$FSBACKUP_GROUP"
fi

if ! id "$FSBACKUP_USER" >/dev/null 2>&1; then
  useradd \
    --system \
    --home /var/lib/fsbackup \
    --create-home \
    --shell /usr/sbin/nologin \
    --gid "$FSBACKUP_GROUP" \
    "$FSBACKUP_USER"
fi

# Ensure correct shell (nologin is intentional)
usermod -s /usr/sbin/nologin "$FSBACKUP_USER"

# -----------------------------
# Directory layout
# -----------------------------

# Configuration
mkdir -p /etc/fsbackup

# Libraries
mkdir -p /usr/local/lib/fsbackup

# Executables
mkdir -p /usr/local/sbin

# State
mkdir -p /var/lib/fsbackup/.ssh
mkdir -p /var/lib/fsbackup/log
mkdir -p /var/lib/fsbackup/manifests

# Backup data locations
mkdir -p "$TMP_DIR"
mkdir -p "$SNAPSHOT_DIR"

# -----------------------------
# Ownership
# -----------------------------
chown root:"$FSBACKUP_GROUP" /etc/fsbackup
chown -R root:root /usr/local/lib/fsbackup
chown -R root:root /usr/local/sbin/fs-*.sh || true
chown -R "$FSBACKUP_USER":"$FSBACKUP_GROUP" /var/lib/fsbackup
chown -R "$FSBACKUP_USER":"$FSBACKUP_GROUP" "$TMP_DIR" "$SNAPSHOT_DIR"

# -----------------------------
# Permissions
# -----------------------------
chmod 750 /etc/fsbackup
chmod 755 /usr/local/lib/fsbackup
chmod 700 /var/lib/fsbackup
chmod 700 /var/lib/fsbackup/.ssh
chmod 750 /var/lib/fsbackup/log
chmod 750 /var/lib/fsbackup/manifests
chmod 750 "$TMP_DIR"
chmod 750 "$SNAPSHOT_DIR"

# Optional files (only chmod if present)
[[ -f /etc/fsbackup/targets.yml ]]        && chmod 640 /etc/fsbackup/targets.yml
[[ -f /etc/fsbackup/fsbackup.env ]]       && chmod 640 /etc/fsbackup/fsbackup.env
[[ -f /etc/fsbackup/credentials.env ]]    && chmod 600 /etc/fsbackup/credentials.env
[[ -f /usr/local/lib/fsbackup/fs-exporter.sh ]] && chmod 644 /usr/local/lib/fsbackup/fs-exporter.sh

chmod 755 /usr/local/sbin/fs-runner.sh 2>/dev/null || true
chmod 755 /usr/local/sbin/fs-snapshot.sh 2>/dev/null || true
chmod 755 /usr/local/sbin/fs-prune.sh 2>/dev/null || true
chmod 755 /usr/local/sbin/fs-export-s3.sh 2>/dev/null || true

# -----------------------------
# SSH key generation (idempotent)
# -----------------------------
SSH_KEY_PATH="/var/lib/fsbackup/.ssh/${SSH_KEY_NAME}"

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  sudo -u "$FSBACKUP_USER" ssh-keygen \
    -t ed25519 \
    -f "$SSH_KEY_PATH" \
    -N "" \
    -C "fsbackup@$(hostname -s)"
fi

chmod 600 "$SSH_KEY_PATH"
chmod 644 "${SSH_KEY_PATH}.pub"

# -----------------------------
# Node exporter permissions
# -----------------------------
mkdir -p "$NODE_EXPORTER_TEXTFILE"
chown "$FSBACKUP_USER":"$FSBACKUP_GROUP" "$NODE_EXPORTER_TEXTFILE"
chmod 755 "$NODE_EXPORTER_TEXTFILE"

# -----------------------------
# Write-access verification
# -----------------------------
sudo -u "$FSBACKUP_USER" touch /var/lib/fsbackup/log/.write_test
sudo -u "$FSBACKUP_USER" touch "$TMP_DIR/.write_test"
sudo -u "$FSBACKUP_USER" touch "$NODE_EXPORTER_TEXTFILE/.write_test"

rm -f \
  /var/lib/fsbackup/log/.write_test \
  "$TMP_DIR/.write_test" \
  "$NODE_EXPORTER_TEXTFILE/.write_test"

# -----------------------------
# Operator summary
# -----------------------------
echo
echo "fsbackup bootstrap complete."
echo
echo "Backup user:      $FSBACKUP_USER"
echo "Backup root:      $BAK_ROOT"
echo "Snapshot dir:     $SNAPSHOT_DIR"
echo "Temp dir:         $TMP_DIR"
echo
echo "SSH public key (install on source hosts):"
echo "  ${SSH_KEY_PATH}.pub"
echo
echo "This script is safe to re-run at any time."
echo

