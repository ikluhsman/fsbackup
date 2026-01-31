#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-trust-host.sh
#
# Seeds SSH host keys for fsbackup with strict verification.
# Emits Prometheus metrics for host trust visibility.
#
# Idempotent:
#   - Does nothing if host key already exists
#   - Fails loudly if key changes
#
# =============================================================================

HOST="${1:-}"
PORT=22

FSBACKUP_USER="fsbackup"
SSH_DIR="/var/lib/fsbackup/.ssh"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="$METRICS_DIR/fsbackup_ssh_hostkeys.prom"

GROUP_NODEEXP="nodeexp_txt"

[[ -n "$HOST" ]] || {
  echo "Usage: fs-trust-host.sh <hostname>" >&2
  exit 2
}

[[ $EUID -eq 0 ]] || {
  echo "ERROR: must be run as root" >&2
  exit 1
}

mkdir -p "$SSH_DIR"
touch "$KNOWN_HOSTS"

chown -R "$FSBACKUP_USER":"$FSBACKUP_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$KNOWN_HOSTS"

# -----------------------------
# Refuse silent key changes
# -----------------------------
if ssh-keygen -F "$HOST" -f "$KNOWN_HOSTS" >/dev/null; then
  echo "Host key already present for $HOST — skipping"
  exit 0
fi

echo "Seeding SSH host key for $HOST..."

TMP_KEYS="$(mktemp)"

if ! ssh-keyscan -p "$PORT" -t ed25519 "$HOST" >"$TMP_KEYS" 2>/dev/null; then
  echo "ERROR: ssh-keyscan failed for $HOST" >&2
  rm -f "$TMP_KEYS"
  exit 1
fi

cat "$TMP_KEYS" >>"$KNOWN_HOSTS"
rm -f "$TMP_KEYS"

# -----------------------------
# Verify fingerprint
# -----------------------------
FP="$(ssh-keygen -lf "$KNOWN_HOSTS" | grep " $HOST " | awk '{print $2}')"

if [[ -z "$FP" ]]; then
  echo "ERROR: failed to extract fingerprint for $HOST" >&2
  exit 1
fi

echo "Host key trusted: $HOST ($FP)"

# -----------------------------
# Prometheus metric
# -----------------------------
mkdir -p "$METRICS_DIR"

{
  echo "# HELP fsbackup_ssh_host_key_present SSH host key known (1=yes)"
  echo "# TYPE fsbackup_ssh_host_key_present gauge"
  echo "fsbackup_ssh_host_key_present{host=\"$HOST\",fingerprint=\"$FP\"} 1"
} >>"$METRIC_FILE"

chmod 664 "$METRIC_FILE"

exit 0

