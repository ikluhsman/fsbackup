#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup-bootstrap.sh
#
# Idempotent bootstrap + updater for FS backup node.
#
# Usage:
#   fsbackup-bootstrap.sh [--update]
#     [--bak-root /bak]
#     [--tmp-dir /bak/tmp]
#     [--snapshot-dir /bak/snapshots]
#
# =============================================================================

# -----------------------------
# Defaults (overridable)
# -----------------------------
BAK_ROOT="/bak"
TMP_DIR=""
SNAPSHOT_DIR=""

FSBACKUP_USER="fsbackup"
FSBACKUP_GROUP="fsbackup"
SSH_KEY_NAME="id_ed25519_backup"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"

UPDATE=0

# Source-of-truth directory (where this script lives)
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_BIN_DIR="${BOOTSTRAP_DIR}/bin"
SRC_LIB_DIR="${BOOTSTRAP_DIR}/lib"

# Required components
REQUIRED_LIBS=(
  /usr/local/lib/fsbackup/fs-exporter.sh
)

REQUIRED_BINS=(
  /usr/local/sbin/fs-runner.sh
  /usr/local/sbin/fs-snapshot.sh
  /usr/local/sbin/fs-promote.sh
  /usr/local/sbin/fs-prune.sh
  /usr/local/sbin/fs-export-s3.sh
)

# -----------------------------
# Argument parsing
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bak-root)      BAK_ROOT="$2"; shift 2 ;;
    --tmp-dir)       TMP_DIR="$2"; shift 2 ;;
    --snapshot-dir)  SNAPSHOT_DIR="$2"; shift 2 ;;
    --update)        UPDATE=1; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

TMP_DIR="${TMP_DIR:-${BAK_ROOT}/tmp}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${BAK_ROOT}/snapshots}"

# -----------------------------
# Sanity checks
# -----------------------------
[[ $EUID -eq 0 ]] || { echo "ERROR: must be run as root"; exit 1; }
mountpoint -q "$BAK_ROOT" || { echo "ERROR: $BAK_ROOT is not mounted"; exit 1; }

# -----------------------------
# Ensure fsbackup user & group
# -----------------------------
getent group "$FSBACKUP_GROUP" >/dev/null || groupadd "$FSBACKUP_GROUP"

if ! id "$FSBACKUP_USER" >/dev/null 2>&1; then
  useradd \
    --system \
    --home /var/lib/fsbackup \
    --create-home \
    --shell /usr/sbin/nologin \
    --gid "$FSBACKUP_GROUP" \
    "$FSBACKUP_USER"
fi

# Ensure non-interactive shell (intentional)
usermod -s /usr/sbin/nologin "$FSBACKUP_USER"

# -----------------------------
# Directory layout
# -----------------------------
mkdir -p \
  /etc/fsbackup \
  /usr/local/lib/fsbackup \
  /usr/local/sbin \
  /var/lib/fsbackup/.ssh \
  /var/lib/fsbackup/log \
  /var/lib/fsbackup/manifests \
  "$TMP_DIR" \
  "$SNAPSHOT_DIR"

# -----------------------------
# Install / update scripts
# -----------------------------
if [[ "$UPDATE" -eq 1 ]]; then
  echo
  echo "Update mode enabled — installing scripts"

  [[ -d "$SRC_BIN_DIR" ]] || { echo "ERROR: missing $SRC_BIN_DIR"; exit 1; }
  [[ -d "$SRC_LIB_DIR" ]] || { echo "ERROR: missing $SRC_LIB_DIR"; exit 1; }

  install -o root -g root -m 0755 \
    "$SRC_BIN_DIR"/fs-*.sh /usr/local/sbin/

  install -o root -g root -m 0644 \
    "$SRC_LIB_DIR"/fs-exporter.sh /usr/local/lib/fsbackup/

  echo "Script installation/update complete"
fi

# -----------------------------
# Ownership
# -----------------------------
chown root:"$FSBACKUP_GROUP" /etc/fsbackup
chown -R root:root /usr/local/lib/fsbackup
chown -R root:root /usr/local/sbin/fs-*.sh 2>/dev/null || true
chown -R "$FSBACKUP_USER":"$FSBACKUP_GROUP" /var/lib/fsbackup
chown -R "$FSBACKUP_USER":"$FSBACKUP_GROUP" "$TMP_DIR" "$SNAPSHOT_DIR"

# -----------------------------
# Permissions
# -----------------------------
chmod 755 /usr/local/lib/fsbackup
chmod 700 /var/lib/fsbackup
chmod 700 /var/lib/fsbackup/.ssh
chmod 750 /var/lib/fsbackup/log /var/lib/fsbackup/manifests
chmod 750 "$TMP_DIR" "$SNAPSHOT_DIR"

# -----------------------------
# Configuration file permissions
# -----------------------------
chown root:"$FSBACKUP_GROUP" /etc/fsbackup
chmod 750 /etc/fsbackup

if [[ -f /etc/fsbackup/targets.yml ]]; then
  chown root:"$FSBACKUP_GROUP" /etc/fsbackup/targets.yml
  chmod 640 /etc/fsbackup/targets.yml
fi

if [[ -f /etc/fsbackup/fsbackup.env ]]; then
  chown root:"$FSBACKUP_GROUP" /etc/fsbackup/fsbackup.env
  chmod 640 /etc/fsbackup/fsbackup.env
fi

if [[ -f /etc/fsbackup/credentials.env ]]; then
  chown root:"$FSBACKUP_GROUP" /etc/fsbackup/credentials.env
  chmod 600 /etc/fsbackup/credentials.env
fi


# -----------------------------
# Verify required components
# -----------------------------
MISSING=0

echo
echo "Verifying required components..."

for f in "${REQUIRED_LIBS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "  MISSING LIB: $f"
    MISSING=1
  else
    chmod 644 "$f"
  fi
done

for f in "${REQUIRED_BINS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "  MISSING BIN: $f"
    MISSING=1
  else
    chmod 755 "$f"
  fi
done

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
sudo -u "$FSBACKUP_USER" touch \
  /var/lib/fsbackup/log/.write_test \
  "$TMP_DIR/.write_test" \
  "$NODE_EXPORTER_TEXTFILE/.write_test"

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
echo "Backup user:   $FSBACKUP_USER"
echo "Backup root:   $BAK_ROOT"
echo "Snapshots:     $SNAPSHOT_DIR"
echo "Temp dir:      $TMP_DIR"
echo
echo "SSH public key (install on source hosts):"
echo "  ${SSH_KEY_PATH}.pub"
echo

if [[ "$MISSING" -eq 1 ]]; then
  echo "WARNING: One or more required scripts are missing."
  echo "Install them and re-run with --update."
  exit 1
fi

echo "All required components are present."
echo "This script is safe to re-run at any time."
echo

