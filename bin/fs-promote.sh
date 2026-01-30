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
DOW="$(date +%u)"       # 1=Mon
DOM="$(date +%d)"       # 01..31

log "[fs-promote] Starting promotion checks"

promote_one() {
  local class="$1"
  local dest_type="$2"   # weekly|monthly
  local dest_key="$3"    # YYYY-Www or YYYY-MM
  local src="${SNAPSHOT_ROOT}/daily/${TODAY}/${class}"
  local dst="${SNAPSHOT_ROOT}/${dest_type}/${dest_key}/${class}"

  [[ -d "$src" ]] || { log "[fs-promote] No daily source dir: $src"; return 1; }

  mkdir -p "$dst"

  # Hardlink-based copy: if file exists in daily, link-dest makes rsync link it.
  # --delete keeps promoted snapshot consistent with daily.
  rsync -a --delete --link-dest="$src" "$src/" "$dst/" >/dev/null 2>&1 || return 2
  return 0
}

PROMOTED_WEEKLY=0
PROMOTED_MONTHLY=0
FAIL=0

# find classes by scanning daily/<today>/
if [[ -d "${SNAPSHOT_ROOT}/daily/${TODAY}" ]]; then
  mapfile -t CLASSES < <(ls -1 "${SNAPSHOT_ROOT}/daily/${TODAY}" 2>/dev/null || true)
else
  CLASSES=()
fi

if [[ "${#CLASSES[@]}" -eq 0 ]]; then
  log "[fs-promote] No classes found under daily/${TODAY}; nothing to promote"
fi

if [[ "$DOW" -ne 1 ]]; then
  log "[fs-promote] Not Monday — skipping weekly promotion"
else
  for c in "${CLASSES[@]}"; do
    if promote_one "$c" "weekly" "$WEEKKEY"; then
      PROMOTED_WEEKLY=$((PROMOTED_WEEKLY+1))
      log "[fs-promote] Weekly promoted: class=$c -> ${WEEKKEY}"
    else
      log "[fs-promote] Weekly promotion FAILED: class=$c"
      FAIL=$((FAIL+1))
    fi
  done
fi

if [[ "$DOM" != "01" ]]; then
  log "[fs-promote] Not first of month — skipping monthly promotion"
else
  for c in "${CLASSES[@]}"; do
    if promote_one "$c" "monthly" "$MONTHKEY"; then
      PROMOTED_MONTHLY=$((PROMOTED_MONTHLY+1))
      log "[fs-promote] Monthly promoted: class=$c -> ${MONTHKEY}"
    else
      log "[fs-promote] Monthly promotion FAILED: class=$c"
      FAIL=$((FAIL+1))
    fi
  done
fi

log "[fs-promote] Promotion complete"

# Metrics
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
chmod 0644 "$METRIC_FILE" 2>/dev/null || true

exit 0

