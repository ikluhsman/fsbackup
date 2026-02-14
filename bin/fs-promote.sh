#!/usr/bin/env bash
set -u
. /etc/fsbackup/fsbackup.conf

LOG_FILE="/var/lib/fsbackup/log/backup.log"
LOCK_FILE="/var/lock/fsbackup.lock"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${NODE_EXPORTER_TEXTFILE}/fsbackup_promote.prom"

ts(){ date +%Y-%m-%dT%H:%M:%S%z; }
log(){ printf "%s %s\n" "$(ts)" "$*"; }

exec > >(tee -a "$LOG_FILE") 2>&1

exec 9>"$LOCK_FILE"
flock -n 9 || { log "[fs-promote] lock held, skipping"; exit 75; }

TODAY="$(date +%F)"
WEEKKEY="$(date +%G-W%V)"
MONTHKEY="$(date +%Y-%m)"
DOW="$(date +%u)"
DOM="$(date +%d)"

log "[fs-promote] Starting promotion checks"

promote_one() {
  local class="$1"
  local dest_type="$2"
  local dest_key="$3"
  local src="${SNAPSHOT_ROOT}/daily/${TODAY}/${class}"
  local dst="${SNAPSHOT_ROOT}/${dest_type}/${dest_key}/${class}"

  [[ -d "$src" ]] || return 1

  [[ -f "$src/.fsbackup_class_exit_code" ]] || return 3
  [[ "$(cat "$src/.fsbackup_class_exit_code")" -eq 0 ]] || return 4

  mkdir -p "$dst"
  rsync -a --delete --link-dest="$src" "$src/" "$dst/" >/dev/null 2>&1 || return 2
  return 0
}

PROMOTED_WEEKLY=0
PROMOTED_MONTHLY=0
FAIL=0

if [[ -d "${SNAPSHOT_ROOT}/daily/${TODAY}" ]]; then
  mapfile -t CLASSES < <(ls -1 "${SNAPSHOT_ROOT}/daily/${TODAY}" 2>/dev/null || true)
else
  CLASSES=()
fi

if [[ "$DOW" -eq 1 ]]; then
  for c in "${CLASSES[@]}"; do
    promote_one "$c" "weekly" "$WEEKKEY"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      PROMOTED_WEEKLY=$((PROMOTED_WEEKLY+1))
    elif [[ $rc -ne 3 && $rc -ne 4 ]]; then
      FAIL=$((FAIL+1))
    fi
  done
fi

if [[ "$DOM" == "01" ]]; then
  for c in "${CLASSES[@]}"; do
    promote_one "$c" "monthly" "$MONTHKEY"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      PROMOTED_MONTHLY=$((PROMOTED_MONTHLY+1))
    elif [[ $rc -ne 3 && $rc -ne 4 ]]; then
      FAIL=$((FAIL+1))
    fi
  done
fi

now="$(date +%s)"
cat >"$METRIC_FILE" <<EOF
# HELP fsbackup_promote_last_run_seconds Unix timestamp of last promote run
# TYPE fsbackup_promote_last_run_seconds gauge
fsbackup_promote_last_run_seconds $now
# HELP fsbackup_promote_weekly_classes_promoted Number of classes promoted to weekly
# TYPE fsbackup_promote_weekly_classes_promoted gauge
fsbackup_promote_weekly_classes_promoted $PROMOTED_WEEKLY
# HELP fsbackup_promote_monthly_classes_promoted Number of classes promoted to monthly
# TYPE fsbackup_promote_monthly_classes_promoted gauge
fsbackup_promote_monthly_classes_promoted $PROMOTED_MONTHLY
# HELP fsbackup_promote_failures Number of promotion failures
# TYPE fsbackup_promote_failures gauge
fsbackup_promote_failures $FAIL
EOF

chgrp nodeexp_txt "$METRIC_FILE"
chmod 0644 "$METRIC_FILE" 2>/dev/null || true

exit 0

