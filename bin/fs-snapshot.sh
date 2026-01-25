#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-snapshot.sh
#
# Creates a single snapshot for a single backup target and emits Prometheus
# metrics via node_exporter textfile collector.
#
# This script is intentionally boring and explicit.
# =============================================================================

# -----------------------------
# Configuration (static)
# -----------------------------
BAK_ROOT="/bak"
SNAP_ROOT="${BAK_ROOT}/snapshots"
TMP_ROOT="${BAK_ROOT}/tmp/in-progress"
LOG_FILE="/var/logs/fsbackup/fsbackup.log"

METRICS_DIR="/var/lib/node_exporter/textfile_collector"

# SSH options for rsync pulls (FS is the initiator)
RSYNC_SSH_OPTS="-i /var/lib/fsbackup/.ssh/id_ed25519_backup -o BatchMode=yes -o StrictHostKeyChecking=yes"

# Import metrics emitter
# shellcheck source=/usr/local/lib/fs-exporter.sh
source /usr/local/lib/fs-exporter.sh

# -----------------------------
# Arguments (one target per run)
# -----------------------------
TARGET_ID=""
CLASS=""
HOST=""            # "fs" / "local" for local sources, or "backup@hs" / "hs" etc for remote
SNAPSHOT_TYPE=""   # daily | weekly | monthly | annual
SOURCE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-id) TARGET_ID="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --snapshot-type) SNAPSHOT_TYPE="$2"; shift 2 ;;
    --source) SOURCE_PATH="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# -----------------------------
# Validation
# -----------------------------
[[ -n "$TARGET_ID" ]]     || { echo "Missing --target-id"; exit 2; }
[[ -n "$CLASS" ]]         || { echo "Missing --class"; exit 2; }
[[ -n "$HOST" ]]          || { echo "Missing --host"; exit 2; }
[[ -n "$SNAPSHOT_TYPE" ]] || { echo "Missing --snapshot-type"; exit 2; }
[[ -n "$SOURCE_PATH" ]]   || { echo "Missing --source"; exit 2; }

METRICS_FILE="${METRICS_DIR}/fs_backup__${TARGET_ID}.prom"

# -----------------------------
# Time bookkeeping
# -----------------------------
START_TS="$(date +%s)"
END_TS=0
STATUS=1
ERROR_CODE=99
BYTES=0
FILE_COUNT=0
SNAPSHOT_SIZE_BYTES=0

# -----------------------------
# Logging helper
# -----------------------------
log() {
  echo "$(date -Is) [$TARGET_ID] $*" >>"$LOG_FILE"
}

# -----------------------------
# Failure exit handler
# -----------------------------
fail() {
  local code="$1"
  local msg="$2"

  END_TS="$(date +%s)"
  ERROR_CODE="$code"
  STATUS=1

  log "ERROR ($code): $msg"

  emit_backup_metrics \
    --metrics-file "$METRICS_FILE" \
    --target-id "$TARGET_ID" \
    --class "$CLASS" \
    --host "$HOST" \
    --snapshot-type "$SNAPSHOT_TYPE" \
    --status "$STATUS" \
    --error-code "$ERROR_CODE" \
    --start-ts "$START_TS" \
    --end-ts "$END_TS" \
    --duration "$((END_TS-START_TS))" \
    --bytes "$BYTES"

  exit 1
}

# -----------------------------
# Guardrails
# -----------------------------
mountpoint -q "$BAK_ROOT" || fail 12 "/bak not mounted"

# Only validate source path locally. Remote paths must be validated by rsync.
if [[ "$HOST" == "local" || "$HOST" == "fs" ]]; then
  [[ -d "$SOURCE_PATH" ]] || fail 10 "Source path missing: $SOURCE_PATH"
fi

mkdir -p "$TMP_ROOT" "$(dirname "$LOG_FILE")" "$METRICS_DIR"

# -----------------------------
# Snapshot naming
# -----------------------------
case "$SNAPSHOT_TYPE" in
  daily)   SNAP_NAME="$(date +%F)" ;;
  weekly)  SNAP_NAME="$(date +%G-W%V)" ;;
  monthly) SNAP_NAME="$(date +%Y-%m)" ;;
  annual)  SNAP_NAME="$(date +%Y)" ;;
  *) fail 99 "Invalid snapshot type: $SNAPSHOT_TYPE" ;;
esac

FINAL_SNAP="${SNAP_ROOT}/${SNAPSHOT_TYPE}/${SNAP_NAME}/${CLASS}/${TARGET_ID}"
TMP_SNAP="${TMP_ROOT}/${TARGET_ID}.$$"

mkdir -p "$(dirname "$FINAL_SNAP")"
rm -rf "$TMP_SNAP"
mkdir -p "$TMP_SNAP"

# Ensure we don't leave junk behind if something fails mid-run
trap 'rm -rf "$TMP_SNAP"' EXIT

# -----------------------------
# Build rsync source (Option A: no trailing slash here)
# -----------------------------
if [[ "$HOST" == "local" || "$HOST" == "fs" ]]; then
  RSYNC_SOURCE="$SOURCE_PATH"
else
  RSYNC_SOURCE="${HOST}:${SOURCE_PATH}"
fi

# -----------------------------
# Determine previous snapshot (avoid self-reference)
# -----------------------------
PREV_SNAP=""
PREV_BASE="${SNAP_ROOT}/${SNAPSHOT_TYPE}"

if [[ -d "$PREV_BASE" ]]; then
  PREV_NAME="$(ls -1 "$PREV_BASE" 2>/dev/null | grep -v "^${SNAP_NAME}$" | sort | tail -n 1 || true)"
  if [[ -n "${PREV_NAME:-}" && -d "${PREV_BASE}/${PREV_NAME}/${CLASS}/${TARGET_ID}" ]]; then
    PREV_SNAP="${PREV_BASE}/${PREV_NAME}/${CLASS}/${TARGET_ID}"
  fi
fi

# -----------------------------
# Run rsync
# -----------------------------
log "Starting snapshot ($SNAPSHOT_TYPE) from ${RSYNC_SOURCE}"

RSYNC_LOG="$(mktemp)"

if [[ -n "$PREV_SNAP" ]]; then
  rsync -a --numeric-ids --delete \
    --link-dest="$PREV_SNAP" \
    -e "ssh ${RSYNC_SSH_OPTS}" \
    --stats \
    "${RSYNC_SOURCE}/" \
    "${TMP_SNAP}/" \
    >"$RSYNC_LOG" 2>&1 || fail 20 "rsync failed (incremental)"
else
  rsync -a --numeric-ids --delete \
    -e "ssh ${RSYNC_SSH_OPTS}" \
    --stats \
    "${RSYNC_SOURCE}/" \
    "${TMP_SNAP}/" \
    >"$RSYNC_LOG" 2>&1 || fail 20 "rsync failed (full)"
fi

# -----------------------------
# Parse rsync stats (more robust)
# -----------------------------
BYTES="$(awk -F': ' '/Total transferred file size/ {print $2}' "$RSYNC_LOG" | awk '{print $1}' | tr -d ',')"
BYTES="${BYTES:-0}"

# -----------------------------
# Finalize snapshot atomically
# -----------------------------
# Remove existing final snapshot if re-running same snapshot name (rare, but safe)
# You may choose to disable this if you want "first run wins" behavior.
if [[ -e "$FINAL_SNAP" ]]; then
  fail 30 "Final snapshot path already exists: $FINAL_SNAP"
fi

mv "$TMP_SNAP" "$FINAL_SNAP"

# Once moved into place, disable temp cleanup trap
trap - EXIT

# -----------------------------
# Snapshot metrics
# -----------------------------
FILE_COUNT="$(find "$FINAL_SNAP" -type f | wc -l)"
SNAPSHOT_SIZE_BYTES="$(du -sb "$FINAL_SNAP" | awk '{print $1}')"

# -----------------------------
# Success
# -----------------------------
END_TS="$(date +%s)"
STATUS=0
ERROR_CODE=0

log "Snapshot completed successfully"

emit_backup_metrics \
  --metrics-file "$METRICS_FILE" \
  --target-id "$TARGET_ID" \
  --class "$CLASS" \
  --host "$HOST" \
  --snapshot-type "$SNAPSHOT_TYPE" \
  --status "$STATUS" \
  --error-code "$ERROR_CODE" \
  --start-ts "$START_TS" \
  --end-ts "$END_TS" \
  --duration "$((END_TS-START_TS))" \
  --bytes "$BYTES" \
  --file-count "$FILE_COUNT" \
  --snapshot-size-bytes "$SNAPSHOT_SIZE_BYTES"

exit 0

