#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-retention.sh — prune old ZFS snapshots by type (v2.0)
#
# Keeps the N most recent snapshots of each type per target dataset.
# Retention counts can be overridden in fsbackup.conf:
#
#   KEEP_DAILY=14
#   KEEP_WEEKLY=8
#   KEEP_MONTHLY=12
#   KEEP_ANNUAL=0    # 0 = keep all
#
# Usage:
#   fs-retention.sh [--dry-run]
# =============================================================================

. /etc/fsbackup/fsbackup.conf

PRIMARY_SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"
ZFS_BASE="${PRIMARY_SNAPSHOT_ROOT#/}"

KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_ANNUAL="${KEEP_ANNUAL:-0}"   # 0 = keep all

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
  esac
done

LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/retention.log"
NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
PROM_OUT="${NODEEXP_DIR}/fsbackup_retention.prom"

mkdir -p "$LOG_DIR"

exec 9>/run/lock/fsbackup-retention.lock
flock -n 9 || { echo "$(date -Is) [retention] already running, exiting"; exit 0; }

log() { echo "$(date -Is) [retention] $*" | tee -a "$LOG_FILE"; }

# keep_count_for_type <type> → echo the keep count (0 = unlimited)
keep_count_for_type() {
  case "$1" in
    daily)   echo "$KEEP_DAILY" ;;
    weekly)  echo "$KEEP_WEEKLY" ;;
    monthly) echo "$KEEP_MONTHLY" ;;
    annual)  echo "$KEEP_ANNUAL" ;;
    *)       echo 0 ;;
  esac
}

START_TS="$(date +%s)"
DESTROYED=0
KEPT=0
FAILED=0

[[ "$DRY_RUN" -eq 1 ]] && log "DRY RUN — no snapshots will be destroyed"
log "Starting retention pruning (daily=${KEEP_DAILY} weekly=${KEEP_WEEKLY} monthly=${KEEP_MONTHLY} annual=${KEEP_ANNUAL:-unlimited})"

# Collect all snapshot names, grouped by dataset
declare -A snap_lists   # dataset -> space-separated list of snapnames sorted oldest-first

while IFS= read -r line; do
  [[ "$line" == *"@"* ]] || continue
  dataset="${line%%@*}"
  snapname="${line##*@}"
  [[ -z "${snap_lists[$dataset]+x}" ]] && snap_lists["$dataset"]=""
  snap_lists["$dataset"]+="${snapname} "
done < <(zfs list -t snapshot -r -H -o name "$ZFS_BASE" 2>/dev/null | sort)

for dataset in "${!snap_lists[@]}"; do
  # Group snapshots by type
  declare -A by_type
  for snapname in ${snap_lists[$dataset]}; do
    type="${snapname%%-*}"
    [[ -z "${by_type[$type]+x}" ]] && by_type["$type"]=""
    by_type["$type"]+="${snapname} "
  done

  for type in "${!by_type[@]}"; do
    keep="$(keep_count_for_type "$type")"
    # Build sorted array (oldest first — sort is already applied above)
    mapfile -t snaps <<< "$(echo "${by_type[$type]}" | tr ' ' '\n' | grep -v '^$' | sort)"
    total="${#snaps[@]}"

    if [[ "$keep" -eq 0 || "$total" -le "$keep" ]]; then
      log "KEEP  ${dataset} ${type}: total=${total} keep=${keep:-unlimited} → nothing to prune"
      KEPT=$((KEPT + total))
      unset "by_type[$type]"
      continue
    fi

    prune_count=$(( total - keep ))
    KEPT=$((KEPT + keep))

    for (( i=0; i<prune_count; i++ )); do
      snap="${snaps[$i]}"
      full="${dataset}@${snap}"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY   zfs destroy ${full}"
        DESTROYED=$((DESTROYED + 1))
      else
        log "DESTROY ${full}"
        if zfs destroy "$full" 2>>"$LOG_FILE"; then
          DESTROYED=$((DESTROYED + 1))
        else
          log "ERROR  failed to destroy ${full}"
          FAILED=$((FAILED + 1))
        fi
      fi
    done
    unset "by_type[$type]"
  done

  unset by_type
  declare -A by_type
done

END_TS="$(date +%s)"
DURATION=$(( END_TS - START_TS ))
EXIT_CODE=$([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)

log "Retention complete: destroyed=${DESTROYED} kept=${KEPT} failed=${FAILED} duration=${DURATION}s"

# Prometheus metrics
tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_retention_last_run_seconds Unix timestamp of last retention run
# TYPE fsbackup_retention_last_run_seconds gauge
fsbackup_retention_last_run_seconds $(date +%s)

# HELP fsbackup_retention_last_exit_code Exit code of last retention run (0=success)
# TYPE fsbackup_retention_last_exit_code gauge
fsbackup_retention_last_exit_code ${EXIT_CODE}

# HELP fsbackup_retention_destroyed_total Snapshots destroyed in this run
# TYPE fsbackup_retention_destroyed_total gauge
fsbackup_retention_destroyed_total ${DESTROYED}

# HELP fsbackup_retention_kept_total Snapshots kept (within policy) in this run
# TYPE fsbackup_retention_kept_total gauge
fsbackup_retention_kept_total ${KEPT}

# HELP fsbackup_retention_failed_total Snapshots that failed to destroy in this run
# TYPE fsbackup_retention_failed_total gauge
fsbackup_retention_failed_total ${FAILED}

# HELP fsbackup_retention_duration_seconds Duration of retention run in seconds
# TYPE fsbackup_retention_duration_seconds gauge
fsbackup_retention_duration_seconds ${DURATION}
EOF
chgrp nodeexp_txt "$tmp" 2>/dev/null || true
chmod 0644 "$tmp"
mv "$tmp" "$PROM_OUT"

exit "$EXIT_CODE"
