#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-prune.sh
#
# Enforces snapshot retention by deleting entire snapshot directories.
# This script NEVER touches live data.
# =============================================================================

# -----------------------------
# Static configuration
# -----------------------------
BAK_ROOT="/bak"
SNAP_ROOT="${BAK_ROOT}/snapshots"
LOG_FILE="${BAK_ROOT}/logs/prune.log"

METRICS_DIR="/var/lib/node_exporter/textfile_collector"

# Import metrics exporter
# shellcheck source=/usr/local/lib/fs-exporter.sh
source /usr/local/lib/fs-exporter.sh

# -----------------------------
# Arguments
# -----------------------------
SNAPSHOT_TYPE=""     # daily | weekly | monthly | annual
RETENTION_DAYS=""    # integer
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot-type) SNAPSHOT_TYPE="$2"; shift 2 ;;
    --retention-days) RETENTION_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# -----------------------------
# Validation
# -----------------------------
[[ -n "$SNAPSHOT_TYPE" ]]  || { echo "Missing --snapshot-type"; exit 2; }
[[ -n "$RETENTION_DAYS" ]] || { echo "Missing --retention-days"; exit 2; }
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || { echo "--retention-days must be integer"; exit 2; }

TARGET_ROOT="${SNAP_ROOT}/${SNAPSHOT_TYPE}"

[[ -d "$TARGET_ROOT" ]] || {
  echo "Snapshot root missing: $TARGET_ROOT" >&2
  exit 1
}

mkdir -p "$(dirname "$LOG_FILE")" "$METRICS_DIR"

# -----------------------------
# Time bookkeeping
# -----------------------------
START_TS="$(date +%s)"
END_TS=0
STATUS=1
ERROR_CODE=99
DELETED_COUNT=0

METRICS_FILE="${METRICS_DIR}/fs_backup__prune_${SNAPSHOT_TYPE}.prom"

log() {
  echo "$(date -Is) [${SNAPSHOT_TYPE}] $*" >>"$LOG_FILE"
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
    --target-id "prune.${SNAPSHOT_TYPE}" \
    --class "system" \
    --host "local" \
    --snapshot-type "$SNAPSHOT_TYPE" \
    --status "$STATUS" \
    --error-code "$ERROR_CODE" \
    --start-ts "$START_TS" \
    --end-ts "$END_TS" \
    --duration "$((END_TS-START_TS))" \
    --bytes 0

  exit 1
}

# -----------------------------
# Safety guardrails
# -----------------------------
mountpoint -q "$BAK_ROOT" || fail 12 "/bak not mounted"

case "$SNAPSHOT_TYPE" in
  daily|weekly|monthly|annual) ;;
  *) fail 99 "Invalid snapshot type: $SNAPSHOT_TYPE" ;;
esac

log "Starting prune (retention=${RETENTION_DAYS} days, dry-run=${DRY_RUN})"

# -----------------------------
# Find candidates
# -----------------------------
CANDIDATES=()

while IFS= read -r dir; do
  CANDIDATES+=("$dir")
done < <(
  find "$TARGET_ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime "+${RETENTION_DAYS}" \
    -print
)

# -----------------------------
# Execute prune
# -----------------------------
for SNAP in "${CANDIDATES[@]}"; do
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would delete $SNAP"
  else
    log "Deleting snapshot $SNAP"
    rm -rf "$SNAP"
    DELETED_COUNT=$((DELETED_COUNT+1))
  fi
done

# -----------------------------
# Success
# -----------------------------
END_TS="$(date +%s)"
STATUS=0
ERROR_CODE=0

log "Prune completed: deleted=${DELETED_COUNT}"

emit_backup_metrics \
  --metrics-file "$METRICS_FILE" \
  --target-id "prune.${SNAPSHOT_TYPE}" \
  --class "system" \
  --host "local" \
  --snapshot-type "$SNAPSHOT_TYPE" \
  --status "$STATUS" \
  --error-code "$ERROR_CODE" \
  --start-ts "$START_TS" \
  --end-ts "$END_TS" \
  --duration "$((END_TS-START_TS))" \
  --bytes "$DELETED_COUNT"

exit 0

