#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-promote.sh
#
# Promotes snapshots between retention tiers using hardlinks.
# Example:
#   daily  -> weekly
#   weekly -> monthly
#   monthly -> annual
#
# This script NEVER reads live data.
# =============================================================================

# -----------------------------
# Static configuration
# -----------------------------
BAK_ROOT="/bak"
SNAP_ROOT="${BAK_ROOT}/snapshots"
LOG_FILE="${BAK_ROOT}/logs/promote.log"

METRICS_DIR="/var/lib/node_exporter/textfile_collector"

# Import metrics exporter
# shellcheck source=/usr/local/lib/fs-exporter.sh
source /usr/local/lib/fs-exporter.sh

# -----------------------------
# Arguments
# -----------------------------
FROM_TYPE=""
TO_TYPE=""
CLASS=""
TARGET_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM_TYPE="$2"; shift 2 ;;
    --to) TO_TYPE="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --target-id) TARGET_ID="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# -----------------------------
# Validation
# -----------------------------
[[ -n "$FROM_TYPE" ]] || { echo "Missing --from"; exit 2; }
[[ -n "$TO_TYPE" ]]   || { echo "Missing --to"; exit 2; }
[[ -n "$CLASS" ]]     || { echo "Missing --class"; exit 2; }
[[ -n "$TARGET_ID" ]] || { echo "Missing --target-id"; exit 2; }

FROM_ROOT="${SNAP_ROOT}/${FROM_TYPE}"
TO_ROOT="${SNAP_ROOT}/${TO_TYPE}"

[[ -d "$FROM_ROOT" ]] || { echo "Source snapshot root missing: $FROM_ROOT"; exit 1; }
mkdir -p "$TO_ROOT" "$(dirname "$LOG_FILE")" "$METRICS_DIR"

# -----------------------------
# Time bookkeeping
# -----------------------------
START_TS="$(date +%s)"
END_TS=0
STATUS=1
ERROR_CODE=99

METRICS_FILE="${METRICS_DIR}/fs_backup__${TARGET_ID}.prom"

log() {
  echo "$(date -Is) [${TARGET_ID}] $*" >>"$LOG_FILE"
}

fail() {
  local code="$1"
  local msg="$2"

  END_TS="$(date +%s)"
  STATUS=1
  ERROR_CODE="$code"

  log "ERROR ($code): $msg"

  emit_backup_metrics \
    --metrics-file "$METRICS_FILE" \
    --target-id "$TARGET_ID" \
    --class "$CLASS" \
    --host "local" \
    --snapshot-type "$TO_TYPE" \
    --status "$STATUS" \
    --error-code "$ERROR_CODE" \
    --start-ts "$START_TS" \
    --end-ts "$END_TS" \
    --duration "$((END_TS-START_TS))" \
    --bytes 0

  exit 1
}

# -----------------------------
# Snapshot naming
# -----------------------------
case "$TO_TYPE" in
  weekly)  TO_NAME="$(date +%G-W%V)" ;;
  monthly) TO_NAME="$(date +%Y-%m)" ;;
  annual)  TO_NAME="$(date +%Y)" ;;
  *) fail 99 "Invalid TO snapshot type: $TO_TYPE" ;;
esac

# -----------------------------
# Locate most recent source snapshot
# -----------------------------
FROM_NAME="$(ls -1 "$FROM_ROOT" | sort | tail -n 1)"

[[ -n "$FROM_NAME" ]] || fail 10 "No snapshots found in $FROM_ROOT"

FROM_SNAP="${FROM_ROOT}/${FROM_NAME}/${CLASS}/${TARGET_ID}"
TO_SNAP="${TO_ROOT}/${TO_NAME}/${CLASS}/${TARGET_ID}"

[[ -d "$FROM_SNAP" ]] || fail 11 "Source snapshot missing: $FROM_SNAP"

if [[ -d "$TO_SNAP" ]]; then
  log "Target snapshot already exists, skipping promotion"
  STATUS=3
else
  log "Promoting snapshot: $FROM_TYPE/$FROM_NAME -> $TO_TYPE/$TO_NAME"
  mkdir -p "$(dirname "$TO_SNAP")"
  cp -al "$FROM_SNAP" "$TO_SNAP" || fail 20 "cp -al failed"
fi

# -----------------------------
# Success
# -----------------------------
END_TS="$(date +%s)"
STATUS="${STATUS:-0}"
ERROR_CODE=0

emit_backup_metrics \
  --metrics-file "$METRICS_FILE" \
  --target-id "$TARGET_ID" \
  --class "$CLASS" \
  --host "local" \
  --snapshot-type "$TO_TYPE" \
  --status "$STATUS" \
  --error-code "$ERROR_CODE" \
  --start-ts "$START_TS" \
  --end-ts "$END_TS" \
  --duration "$((END_TS-START_TS))" \
  --bytes 0

log "Promotion completed successfully"
exit 0

