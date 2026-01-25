#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-promote.sh
#
# Promotes snapshots between tiers using hardlinks.
# =============================================================================

# -----------------------------
# Configuration
# -----------------------------
BAK_ROOT="/bak"
SNAP_ROOT="${BAK_ROOT}/snapshots"
LOG_FILE="/var/lib/fsbackup/log/backup.log"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"

# Import metrics emitter
# shellcheck source=/usr/local/lib/fsbackup/fs-exporter.sh
source /usr/local/lib/fsbackup/fs-exporter.sh

# -----------------------------
# Arguments
# -----------------------------
FROM=""
TO=""
CLASS=""
DATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)  FROM="$2"; shift 2 ;;
    --to)    TO="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --date)  DATE="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$FROM" ]]  || { echo "Missing --from"; exit 2; }
[[ -n "$TO" ]]    || { echo "Missing --to"; exit 2; }
[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

# -----------------------------
# Validation
# -----------------------------
case "$FROM" in daily|weekly|monthly) ;; *) echo "Invalid --from"; exit 2 ;; esac
case "$TO"   in weekly|monthly|annual) ;; *) echo "Invalid --to"; exit 2 ;; esac

METRICS_FILE="${METRICS_DIR}/fs_promote__${FROM}_to_${TO}_${CLASS}.prom"

# -----------------------------
# Logging helper
# -----------------------------
log() {
  echo "$(date -Is) [PROMOTE ${FROM}->${TO} ${CLASS}] $*" >>"$LOG_FILE"
}

# -----------------------------
# Time bookkeeping
# -----------------------------
START_TS="$(date +%s)"
END_TS=0
STATUS=1
ERROR_CODE=99
TARGET_COUNT=0

fail() {
  local code="$1"
  local msg="$2"

  END_TS="$(date +%s)"
  ERROR_CODE="$code"
  STATUS=1

  log "ERROR ($code): $msg"

  emit_promote_metrics \
    --metrics-file "$METRICS_FILE" \
    --from "$FROM" \
    --to "$TO" \
    --class "$CLASS" \
    --status "$STATUS" \
    --error-code "$ERROR_CODE" \
    --start-ts "$START_TS" \
    --end-ts "$END_TS" \
    --duration "$((END_TS-START_TS))" \
    --targets "$TARGET_COUNT"

  exit 1
}

# -----------------------------
# Determine source snapshot
# -----------------------------
FROM_BASE="${SNAP_ROOT}/${FROM}"

[[ -d "$FROM_BASE" ]] || fail 10 "Source tier missing: $FROM_BASE"

if [[ -n "$DATE" ]]; then
  FROM_DATE="$DATE"
else
  FROM_DATE="$(ls -1 "$FROM_BASE" | sort | tail -n 1)"
fi

FROM_PATH="${FROM_BASE}/${FROM_DATE}/${CLASS}"

[[ -d "$FROM_PATH" ]] || fail 11 "Source snapshot not found: $FROM_PATH"

# -----------------------------
# Determine destination snapshot
# -----------------------------
case "$TO" in
  weekly)  TO_DATE="$(date -d "$FROM_DATE" +%G-W%V)" ;;
  monthly) TO_DATE="$(date -d "$FROM_DATE" +%Y-%m)" ;;
  annual)  TO_DATE="$(date -d "$FROM_DATE" +%Y)" ;;
esac

TO_PATH="${SNAP_ROOT}/${TO}/${TO_DATE}/${CLASS}"

if [[ -e "$TO_PATH" ]]; then
  fail 12 "Destination snapshot already exists: $TO_PATH"
fi

mkdir -p "$(dirname "$TO_PATH")"

# -----------------------------
# Promotion
# -----------------------------
log "Promoting ${FROM}/${FROM_DATE}/${CLASS} -> ${TO}/${TO_DATE}/${CLASS}"

cp -al "$FROM_PATH" "$TO_PATH" || fail 20 "Hardlink promotion failed"

TARGET_COUNT="$(find "$TO_PATH" -mindepth 1 -maxdepth 1 -type d | wc -l)"

# -----------------------------
# Success
# -----------------------------
END_TS="$(date +%s)"
STATUS=0
ERROR_CODE=0

log "Promotion completed successfully (${TARGET_COUNT} targets)"

emit_promote_metrics \
  --metrics-file "$METRICS_FILE" \
  --from "$FROM" \
  --to "$TO" \
  --class "$CLASS" \
  --status "$STATUS" \
  --error-code "$ERROR_CODE" \
  --start-ts "$START_TS" \
  --end-ts "$END_TS" \
  --duration "$((END_TS-START_TS))" \
  --targets "$TARGET_COUNT"

exit 0

