#!/usr/bin/env bash
set -u
# IMPORTANT: no set -e — failures are handled explicitly

# =============================================================================
# fs-snapshot.sh
# =============================================================================

BAK_ROOT="/bak"
SNAP_ROOT="${BAK_ROOT}/snapshots"
TMP_ROOT="${BAK_ROOT}/tmp/in-progress"
LOG_FILE="/var/lib/fsbackup/log/backup.log"

METRICS_DIR="/var/lib/node_exporter/textfile_collector"

RSYNC_SSH_OPTS="-i /var/lib/fsbackup/.ssh/id_ed25519_backup -o BatchMode=yes -o StrictHostKeyChecking=yes"

# shellcheck source=/usr/local/lib/fsbackup/fs-exporter.sh
source /usr/local/lib/fsbackup/fs-exporter.sh

TARGET_ID=""
CLASS=""
HOST=""
SNAPSHOT_TYPE=""
SOURCE_PATH=""
REPLACE_EXISTING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-id) TARGET_ID="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --snapshot-type) SNAPSHOT_TYPE="$2"; shift 2 ;;
    --source) SOURCE_PATH="$2"; shift 2 ;;
    --replace-existing) REPLACE_EXISTING=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

TMP_DIR="/bak/tmp/in-progress/${TARGET_ID}"
RSYNC_LOG="${TMP_DIR}/rsync.log"

mkdir -p "$TMP_DIR"
: > "$RSYNC_LOG"


[[ -n "$TARGET_ID" && -n "$CLASS" && -n "$HOST" && -n "$SNAPSHOT_TYPE" && -n "$SOURCE_PATH" ]] \
  || { echo "Missing required arguments"; exit 2; }

METRICS_FILE="${METRICS_DIR}/fs_backup__${TARGET_ID}.prom"
START_TS="$(date +%s)"

log() {
  echo "$(date -Is) [$TARGET_ID] $*" >>"$LOG_FILE"
}

fail() {
  local code="$1"
  local msg="$2"
  local end_ts
  end_ts="$(date +%s)"

  log "ERROR ($code): $msg"

  emit_backup_metrics \
    --metrics-file "$METRICS_FILE" \
    --target-id "$TARGET_ID" \
    --class "$CLASS" \
    --host "$HOST" \
    --snapshot-type "$SNAPSHOT_TYPE" \
    --status 1 \
    --error-code "$code" \
    --start-ts "$START_TS" \
    --end-ts "$end_ts" \
    --duration "$((end_ts - START_TS))" \
    --bytes 0

  exit "$code"
}

mountpoint -q "$BAK_ROOT" || fail 12 "/bak not mounted"

if [[ "$HOST" == "fs" || "$HOST" == "local" ]]; then
  [[ -e "$SOURCE_PATH" ]] || fail 10 "Source path missing: $SOURCE_PATH"
fi

mkdir -p "$TMP_ROOT" "$(dirname "$LOG_FILE")" "$METRICS_DIR"

case "$SNAPSHOT_TYPE" in
  daily) SNAP_NAME="$(date +%F)" ;;
  weekly) SNAP_NAME="$(date +%G-W%V)" ;;
  monthly) SNAP_NAME="$(date +%Y-%m)" ;;
  annual) SNAP_NAME="$(date +%Y)" ;;
  *) fail 99 "Invalid snapshot type" ;;
esac

FINAL_SNAP="${SNAP_ROOT}/${SNAPSHOT_TYPE}/${SNAP_NAME}/${CLASS}/${TARGET_ID}"
TMP_SNAP="${TMP_ROOT}/${TARGET_ID}"

# -----------------------------
# Snapshot already exists
# -----------------------------
if [[ -e "$FINAL_SNAP" && "$REPLACE_EXISTING" -eq 0 ]]; then
  log "Snapshot already exists, skipping"

  END_TS="$(date +%s)"

  emit_backup_metrics \
    --metrics-file "$METRICS_FILE" \
    --target-id "$TARGET_ID" \
    --class "$CLASS" \
    --host "$HOST" \
    --snapshot-type "$SNAPSHOT_TYPE" \
    --status 0 \
    --error-code 0 \
    --start-ts "$START_TS" \
    --end-ts "$END_TS" \
    --duration "$((END_TS - START_TS))" \
    --bytes 0

  exit 0
fi

[[ "$REPLACE_EXISTING" -eq 1 && -e "$FINAL_SNAP" ]] && rm -rf "$FINAL_SNAP"

if [[ "$HOST" == "fs" || "$HOST" == "local" ]]; then
  RSYNC_SOURCE="${SOURCE_PATH}/"
else
  RSYNC_SOURCE="${HOST}:${SOURCE_PATH}/"
fi

mkdir -p "$(dirname "$FINAL_SNAP")"
rm -rf "$TMP_SNAP"
mkdir -p "$TMP_SNAP"

log "Starting snapshot ($SNAPSHOT_TYPE) from $RSYNC_SOURCE"

RSYNC_LOG="${TMP_SNAP}/rsync.log"
BYTES=0

if ! rsync -a --numeric-ids --delete \
  -e "ssh $RSYNC_SSH_OPTS" \
  --stats \
  "$RSYNC_SOURCE" \
  "$TMP_SNAP/" \
  >"$RSYNC_LOG" 2>&1; then
  fail 20 "rsync failed"
fi

if [[ -f "$RSYNC_LOG" ]]; then
  BYTES="$(awk '/Total transferred file size/ {print $5}' "$RSYNC_LOG" | tr -d ',')"
  BYTES="${BYTES:-0}"
fi

mv "$TMP_SNAP" "$FINAL_SNAP" || fail 32 "Failed to finalize snapshot"

END_TS="$(date +%s)"

log "Snapshot completed successfully"

emit_backup_metrics \
  --metrics-file "$METRICS_FILE" \
  --target-id "$TARGET_ID" \
  --class "$CLASS" \
  --host "$HOST" \
  --snapshot-type "$SNAPSHOT_TYPE" \
  --status 0 \
  --error-code 0 \
  --start-ts "$START_TS" \
  --end-ts "$END_TS" \
  --duration "$((END_TS - START_TS))" \
  --bytes "$BYTES"

exit 0

