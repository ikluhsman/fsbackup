#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-doctor.sh
#
# Read-only diagnostic tool for fsbackup.
# Verifies environment, permissions, SSH access, and config consistency.
#
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
SSH_USER="backup"
FSBACKUP_USER="fsbackup"
SSH_DIR="/var/lib/fsbackup/.ssh"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

REQUIRED_CMDS=(ssh rsync jq yq awk date)

FAIL=0

echo
echo "fsbackup doctor"
echo "================"
echo

# -----------------------------
# Binary checks
# -----------------------------
echo "Checking required commands..."
for c in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$c" >/dev/null; then
    echo "  MISSING: $c"
    FAIL=1
  else
    echo "  OK: $c"
  fi
done
echo

# -----------------------------
# Permissions
# -----------------------------
echo "Checking permissions..."

for p in /bak /bak/tmp /bak/snapshots /etc/fsbackup "$SSH_DIR"; do
  if sudo -u "$FSBACKUP_USER" test -r "$p" -a -w "$p" 2>/dev/null; then
    echo "  OK: fsbackup rw $p"
  else
    echo "  FAIL: fsbackup cannot rw $p"
    FAIL=1
  fi
done
echo

# -----------------------------
# Config validity
# -----------------------------
echo "Validating targets.yml..."
if sudo -u "$FSBACKUP_USER" yq eval '.' "$CONFIG_FILE" >/dev/null; then
  echo "  OK: YAML parses"
else
  echo "  FAIL: YAML invalid"
  FAIL=1
fi
echo

# -----------------------------
# SSH connectivity (read-only)
# -----------------------------
echo "Checking SSH connectivity..."

HOSTS="$(sudo -u "$FSBACKUP_USER" yq eval '.. | .host? // empty' "$CONFIG_FILE" | sort -u)"

for h in $HOSTS; do
  if sudo -u "$FSBACKUP_USER" ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    "$SSH_USER@$h" true >/dev/null 2>&1; then
    echo "  OK: ssh $h"
  else
    echo "  FAIL: ssh $h"
    FAIL=1
  fi
done
echo

# -----------------------------
# Summary
# -----------------------------
if [[ "$FAIL" -eq 0 ]]; then
  echo "Doctor result: HEALTHY"
  exit 0
else
  echo "Doctor result: ISSUES DETECTED"
  exit 1
fi

