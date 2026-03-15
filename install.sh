#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install.sh
#
# Idempotent bootstrap + installer for fsbackup system.
# Safe to re-run at any time.
#
# Usage:
#   install.sh [--update]
#     [--backup-root /backup]
# =============================================================================

# -----------------------------
# Defaults
# -----------------------------
BACKUP_ROOT="/backup"
SNAPSHOT_DIR=""
TMP_DIR=""

FSBACKUP_USER="fsbackup"
FSBACKUP_GROUP="nodeexp_txt"
SSH_KEY_NAME="id_ed25519_backup"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"

UPDATE=0

SUPERCRONIC_VERSION="0.2.33"
SUPERCRONIC_SHA256="feefa310da569c81b99e1027b86b27b51e6ee9ab647747b49099645120cfc671"
SUPERCRONIC_BIN="/usr/local/bin/supercronic"

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_BIN_DIR="${BOOTSTRAP_DIR}/bin"

# Scripts that MUST exist after install
REQUIRED_BINS=(
  fs-runner.sh
  fs-doctor.sh
  fs-promote.sh
  fs-retention.sh
  fs-restore.sh
  fs-nodeexp-fix.sh
  fs-export-s3.sh
  fs-trust-host.sh
)

# -----------------------------
# Arguments
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    --update)      UPDATE=1; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

SNAPSHOT_DIR="${BACKUP_ROOT}/snapshots"
TMP_DIR="${BACKUP_ROOT}/tmp"

# -----------------------------
# Sanity checks
# -----------------------------
[[ $EUID -eq 0 ]] || { echo "ERROR: must be run as root"; exit 1; }
mountpoint -q "$BACKUP_ROOT" || { echo "ERROR: $BACKUP_ROOT is not mounted"; exit 1; }

command -v yq >/dev/null || { echo "ERROR: yq v4 required"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq required"; exit 1; }

# -----------------------------
# supercronic (idempotent)
# -----------------------------
if [[ ! -x "$SUPERCRONIC_BIN" ]]; then
  echo "Installing supercronic v${SUPERCRONIC_VERSION}..."
  curl -fsSL \
    "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    -o "$SUPERCRONIC_BIN"
  echo "${SUPERCRONIC_SHA256}  ${SUPERCRONIC_BIN}" | sha256sum -c -
  chmod +x "$SUPERCRONIC_BIN"
  echo "supercronic installed."
else
  echo "supercronic already installed, skipping."
fi

# -----------------------------
# User & group
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

usermod -s /usr/sbin/nologin "$FSBACKUP_USER"
usermod -aG "$FSBACKUP_GROUP" "$FSBACKUP_USER"

# -----------------------------
# Directories
# -----------------------------
mkdir -p \
  /etc/fsbackup \
  /usr/local/sbin \
  /var/lib/fsbackup/.ssh \
  /var/lib/fsbackup/log \
  "$SNAPSHOT_DIR" \
  "$TMP_DIR"

# -----------------------------
# Install / update scripts
# -----------------------------
if [[ "$UPDATE" -eq 1 ]]; then
  echo "Installing fsbackup scripts"

  [[ -d "$SRC_BIN_DIR" ]] || { echo "ERROR: missing $SRC_BIN_DIR"; exit 1; }

  install -o root -g root -m 0755 \
    "$SRC_BIN_DIR"/fs-*.sh /usr/local/sbin/
fi

# -----------------------------
# Verify required scripts
# -----------------------------
for b in "${REQUIRED_BINS[@]}"; do
  if [[ ! -x "/usr/local/sbin/$b" ]]; then
    echo "ERROR: missing /usr/local/sbin/$b"
    exit 1
  fi
done

# -----------------------------
# Ownership & permissions
# -----------------------------
chown root:"$FSBACKUP_GROUP" /etc/fsbackup
chmod 750 /etc/fsbackup

chown -R "$FSBACKUP_USER":"$FSBACKUP_GROUP" /var/lib/fsbackup
chmod 700 /var/lib/fsbackup
chmod 700 /var/lib/fsbackup/.ssh
chmod 750 /var/lib/fsbackup/log

chown -R "$FSBACKUP_USER":"$FSBACKUP_GROUP" "$SNAPSHOT_DIR" "$TMP_DIR"
chmod 2770 "$SNAPSHOT_DIR"
chmod 2770 "$TMP_DIR"

# Config files (if present)
for f in targets.yml fsbackup.conf credentials.env; do
  if [[ -f "/etc/fsbackup/$f" ]]; then
    chown root:"$FSBACKUP_GROUP" "/etc/fsbackup/$f"
    chmod 640 "/etc/fsbackup/$f"
  fi
done

# -----------------------------
# SSH key (idempotent)
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
# node_exporter textfile dir
# -----------------------------
mkdir -p "$NODE_EXPORTER_TEXTFILE"
chown root:"$FSBACKUP_GROUP" "$NODE_EXPORTER_TEXTFILE"
chmod 2775 "$NODE_EXPORTER_TEXTFILE"

# -----------------------------
# Write test
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
# Summary
# -----------------------------
echo
echo "fsbackup bootstrap complete."
echo "Backup user:   $FSBACKUP_USER"
echo "Snapshot root: $SNAPSHOT_DIR"
echo "Temp dir:      $TMP_DIR"
echo
echo "SSH public key to install on source hosts:"
echo "  ${SSH_KEY_PATH}.pub"
echo
echo "Safe to re-run at any time."
echo

# -----------------------------
# Optional: web UI setup
# -----------------------------
read -rp "Set up the web UI now? [y/N]: " INSTALL_WEB
INSTALL_WEB="${INSTALL_WEB:-N}"
if [[ "${INSTALL_WEB,,}" == "y" ]]; then
  bash "${BOOTSTRAP_DIR}/web/install.sh"
fi

