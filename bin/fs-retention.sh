#!/usr/bin/env bash
set -u
. /etc/fsbackup/fsbackup.conf
LOG_FILE="/var/lib/fsbackup/log/backup.log"
LOCK_FILE="/var/lock/fsbackup.lock"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${NODE_EXPORTER_TEXTFILE}/fsbackup_retention.prom"

KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12

ts(){ date +%Y-%m-%dT%H:%M:%S%z; }
log(){ printf "%s %s\n" "$(ts)" "$*" >&2; }

exec > >(tee -a "$LOG_FILE") 2>&1

exec 9>"$LOCK_FILE"
flock -n 9 || { log "[fs-retention] lock held, skipping"; exit 75; }

prune_dirset() {
  local type="$1" keep="$2"
  local base="${SNAPSHOT_ROOT}/${type}"

  [[ -d "$base" ]] || return 0

  # Sort keys lexicographically works for YYYY-MM-DD, YYYY-MM, YYYY-Www
  mapfile -t KEYS < <(ls -1 "$base" 2>/dev/null | sort || true)
  local total="${#KEYS[@]}"
  local removed=0

  if (( total <= keep )); then
    log "[fs-retention] ${type}: total=${total}, keep=${keep} -> nothing to prune"
    echo "$removed"
    return 0
  fi

  local cut=$((total - keep))
  for ((i=0; i<cut; i++)); do
    local k="${KEYS[$i]}"
    log "[fs-retention] Pruning ${type}/${k}"
    rm -rf --one-file-system "${base}/${k}"
    removed=$((removed+1))
  done

  echo "$removed"
}

log "[fs-retention] Starting retention pruning"
REM_DAILY="$(prune_dirset daily "$KEEP_DAILY")"
REM_WEEKLY="$(prune_dirset weekly "$KEEP_WEEKLY")"
REM_MONTHLY="$(prune_dirset monthly "$KEEP_MONTHLY")"
log "[fs-retention] Complete (daily=${REM_DAILY}, weekly=${REM_WEEKLY}, monthly=${REM_MONTHLY})"

# Metrics
now="$(date +%s)"
tmp="$(mktemp)"

## Ensure unset and empty values are set to 0.
REM_DAILY="${REM_DAILY:-0}"
REM_WEEKLY="${REM_WEEKLY:-0}"
REM_MONTHLY="${REM_MONTHLY:-0}"

cat >"$tmp" <<EOF
# HELP fsbackup_retention_last_run_seconds Unix timestamp of last retention run
# TYPE fsbackup_retention_last_run_seconds gauge
fsbackup_retention_last_run_seconds $now

# HELP fsbackup_retention_removed_daily Number of daily snapshot keys removed
# TYPE fsbackup_retention_removed_daily gauge
fsbackup_retention_removed_daily $REM_DAILY

# HELP fsbackup_retention_removed_weekly Number of weekly snapshot keys removed
# TYPE fsbackup_retention_removed_weekly gauge
fsbackup_retention_removed_weekly $REM_WEEKLY

# HELP fsbackup_retention_removed_monthly Number of monthly snapshot keys removed
# TYPE fsbackup_retention_removed_monthly gauge
fsbackup_retention_removed_monthly $REM_MONTHLY
EOF

chmod 0644 "$tmp"
mv "$tmp" "$METRIC_FILE"

exit 0

