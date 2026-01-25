#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-prune.sh
#
# Enforces snapshot retention policy.
# =============================================================================

# -----------------------------
# Configuration
# -----------------------------
BAK_ROOT="/bak"
SNAP_ROOT="${BAK_ROOT}/snapshots"
LOG_FILE="/var/lib/fsbackup/log/backup.log"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"

# Retention (adjust later if desired)
RETENTION_DAILY_DAYS=7
RETENTION_WEEKLY_WEEKS=5
RETENTION_MONTHLY_MONTHS=12

# Import metrics emitter
# shellcheck source=/usr/local/lib/fsbackup/fs-exporter.sh
source /usr/local/lib/fsbackup/fs-exporter.sh

# -----------------------------
# Arguments
# -----------------------------
TIER=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$TIER" ]] || { echo "Missing --tier"; exit 2; }

case "$TIER" in
  daily|weekly|monthly) ;;
  annual)
    echo "Annual snapshots are never pruned"
    exit 0
    ;;
  *)
    echo "Invalid tier: $TIER"
    exit 2
    ;;
esac

METRICS_FILE="${METRICS_DIR}/fs_prune__${TIER}.prom"

# -----------------------------
# Helpers
# -----------------------------
log() {
  echo "$(date -Is) [PRUNE ${TIER}] $*" >>"$LOG_FILE"
}

START_TS="$(date +%s)"
END_TS=0
STATUS=1
ERROR_CODE=99
PRUNED_COUNT=0

fail() {
  local code="$1"
  local msg="$2"

  END_TS="$(date +%s)"
  ERROR_CODE="$code"
  STATUS=1

  log "ERROR ($code): $msg"

  emit_prune_metrics \
    --metrics-file "$METRICS_FILE" \
    --tier "$TIER" \
    --status "$STATUS" \
    --error-code "$ERROR_CODE" \
    --start-ts "$START_TS" \
    --end-ts "$END_TS" \
    --duration "$((END_TS-START_TS))" \
    --pruned "$PRUNED_COUNT"

  exit 1
}

# -----------------------------
# Determine cutoff
# -----------------------------
NOW="$(date +%s)"

case "$TIER" in
  daily)
    CUTOFF="$(date -d "-${RETENTION_DAILY_DAYS} days" +%s)"
    NEXT_TIER="weekly"
    ;;
  weekly)
    CUTOFF="$(date -d "-${RETENTION_WEEKLY_WEEKS} weeks" +%s)"
    NEXT_TIER="monthly"
    ;;
  monthly)
    CUTOFF="$(date -d "-${RETENTION_MONTHLY_MONTHS} months" +%s)"
    NEXT_TIER="annual"
    ;;
esac

TIER_PATH="${SNAP_ROOT}/${TIER}"

[[ -d "$TIER_PATH" ]] || exit 0

# -----------------------------
# Safety: ensure next tier exists
# -----------------------------
if [[ "$NEXT_TIER" != "annual" && ! -d "${SNAP_ROOT}/${NEXT_TIER}" ]]; then
  fail 10 "Next tier ${NEXT_TIER} does not exist; refusing to prune ${TIER}"
fi

# -----------------------------
# Prune
# -----------------------------
for SNAP in "$TIER_PATH"/*; do
  SNAP_NAME="$(basename "$SNAP")"

  # Parse snapshot date
  case "$TIER" in
    daily)
      SNAP_TS="$(date -d "$SNAP_NAME" +%s 2>/dev/null || echo 0)"
      ;;
    weekly)
      SNAP_TS="$(date -d "${SNAP_NAME}-1" +%s 2>/dev/null || echo 0)"
      ;;
    monthly)
      SNAP_TS="$(date -d "${SNAP_NAME}-01" +%s 2>/dev/null || echo 0)"
      ;;
  esac

  [[ "$SNAP_TS" -gt 0 ]] || continue

  if [[ "$SNAP_TS" -lt "$CUTOFF" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN: would prune ${TIER}/${SNAP_NAME}"
    else
      log "Pruning ${TIER}/${SNAP_NAME}"
      rm -rf "$SNAP"
      PRUNED_COUNT=$((PRUNED_COUNT+1))
    fi
  fi
done

# -----------------------------
# Success
# -----------------------------
END_TS="$(date +%s)"
STATUS=0
ERROR_CODE=0

emit_prune_metrics \
  --metrics-file "$METRICS_FILE" \
  --tier "$TIER" \
  --status "$STATUS" \
  --error-code "$ERROR_CODE" \
  --start-ts "$START_TS" \
  --end-ts "$END_TS" \
  --duration "$((END_TS-START_TS))" \
  --pruned "$PRUNED_COUNT"

exit 0

