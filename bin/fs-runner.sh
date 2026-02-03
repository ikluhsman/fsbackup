#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-runner.sh — snapshot executor with merge-safe metrics
# =============================================================================

. /etc/fsbackup/fsbackup.conf

CONFIG_FILE="/etc/fsbackup/targets.yml"
LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/backup.log"

NODE_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

BACKUP_SSH_USER="backup"
MAX_EXCLUDES=15

SNAPSHOT_TYPE="$1"   # daily | weekly | monthly
shift || true

CLASS=""
TARGET_FILTER=""
DRY_RUN=0
REPLACE=0

usage() {
  echo "Usage: fs-runner.sh <daily|weekly|monthly> --class <class> [--target <id>] [--dry-run] [--replace-existing]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --target) TARGET_FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$CLASS" ]] || usage
mkdir -p "$LOG_DIR"

PROM_FILE="${NODE_TEXTFILE_DIR}/fsbackup_runner_${CLASS}.prom"

RUN_SCOPE_FULL=1
[[ -n "$TARGET_FILTER" ]] && RUN_SCOPE_FULL=0
NOW_EPOCH="$(date +%s)"

log() {
  local id="$1"; shift
  echo "$(date -Is) [$id] $*" | tee -a "$LOG_FILE"
}

is_local_host() {
  local h="$1"
  [[ "$h" == "localhost" ]] && return 0
  [[ "$h" == "$(hostname -s)" ]] && return 0
  [[ "$h" == "$(hostname -f 2>/dev/null)" ]] && return 0

  for ip in $(hostname -I 2>/dev/null); do
    getent hosts "$h" | awk '{print $1}' | grep -qx "$ip" && return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# Load targets
# -----------------------------------------------------------------------------

if [[ -n "$TARGET_FILTER" ]]; then
  mapfile -t TARGETS < <(
    yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" \
    | jq -c "select(.id == \"${TARGET_FILTER}\")"
  )
else
  mapfile -t TARGETS < <(
    yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
  )
fi

[[ "${#TARGETS[@]}" -eq 0 ]] && { echo "Target not found: ${TARGET_FILTER}"; exit 2; }


DATE_STR="$(date +%F)"
DEST_BASE="${SNAPSHOT_ROOT}/${SNAPSHOT_TYPE}/${DATE_STR}/${CLASS}"

echo "$(date -Is) fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Target filter: ${TARGET_FILTER:-<none>}"
echo

# -----------------------------------------------------------------------------
# PREFLIGHT
# -----------------------------------------------------------------------------
for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"

  if is_local_host "$host"; then
    [[ -e "$src" ]] || { echo "→ $id FAIL (missing)"; exit 1; }
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
      "${BACKUP_SSH_USER}@${host}" "test -e '$src'" \
      || { echo "→ $id FAIL (ssh/path)"; exit 1; }
  fi
done

# -----------------------------------------------------------------------------
# EXECUTION
# -----------------------------------------------------------------------------
TOTAL=0
SUCCEEDED=0
FAILED=0

PROM_NEW="$(mktemp)"

for t in "${TARGETS[@]}"; do
  ((TOTAL++))
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$t")"

  DEST="${DEST_BASE}/${id}"
  EXCLUDE_FILE="$(mktemp)"
  RSYNC_ERR="$(mktemp)"

  mkdir -p "$DEST"
  log "$id" "Starting snapshot"

  RSYNC_CMD=(rsync -a --delete)
  [[ "$DRY_RUN" -eq 1 ]] && RSYNC_CMD+=(-n)
  [[ "$REPLACE" -eq 0 ]] && RSYNC_CMD+=(--ignore-existing)
  [[ -n "$rsync_opts" ]] && RSYNC_CMD+=($rsync_opts)

  TOTAL_EXCLUDES=0
  AUTO_EXCLUDE_USED=0

  while true; do
    if is_local_host "$host"; then
      "${RSYNC_CMD[@]}" --exclude-from="$EXCLUDE_FILE" "${src%/}/" "$DEST/" 2>"$RSYNC_ERR" && break
    else
      "${RSYNC_CMD[@]}" --exclude-from="$EXCLUDE_FILE" "${BACKUP_SSH_USER}@${host}:${src%/}/" "$DEST/" 2>"$RSYNC_ERR" && break
    fi

    err_path="$(grep -oE '/[^"]+' "$RSYNC_ERR" | head -n1)"
    [[ -z "$err_path" ]] && break

    ((TOTAL_EXCLUDES++))
    (( TOTAL_EXCLUDES > MAX_EXCLUDES )) && break
    echo "${err_path}/**" >>"$EXCLUDE_FILE"
    AUTO_EXCLUDE_USED=1
  done

  rc=$?

  if [[ $rc -eq 0 ]]; then
    ((SUCCEEDED++))
    SNAP_BYTES="$(du -sb "$DEST" 2>/dev/null | awk '{print $1}' || echo 0)"

    cat >>"$PROM_NEW" <<EOF
fsbackup_snapshot_last_success{class="${CLASS}",target="${id}"} ${NOW_EPOCH}
fsbackup_snapshot_bytes{class="${CLASS}",target="${id}"} ${SNAP_BYTES}
fsbackup_excludes_total{class="${CLASS}",target="${id}"} ${TOTAL_EXCLUDES}
fsbackup_auto_exclude_used{class="${CLASS}",target="${id}"} ${AUTO_EXCLUDE_USED}
fsbackup_runner_target_last_seen{class="${CLASS}",target="${id}"} ${NOW_EPOCH}
fsbackup_runner_target_last_exit_code{class="${CLASS}",target="${id}"} 0
EOF
  else
    ((FAILED++))
    cat >>"$PROM_NEW" <<EOF
fsbackup_runner_target_last_seen{class="${CLASS}",target="${id}"} ${NOW_EPOCH}
fsbackup_runner_target_last_exit_code{class="${CLASS}",target="${id}"} ${rc}
fsbackup_runner_target_failures_total{class="${CLASS}",target="${id}"} 1
EOF
  fi

  rm -f "$RSYNC_ERR" "$EXCLUDE_FILE"
done

# -----------------------------------------------------------------------------
# METRIC MERGE (correct, counter-safe)
# -----------------------------------------------------------------------------
PROM_MERGED="$(mktemp)"

# 1. Start with existing metrics (if any)
if [[ -f "$PROM_FILE" ]]; then
  cat "$PROM_FILE" >"$PROM_MERGED"
fi

# 2. Remove all metrics for targets we just processed
for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  sed -i "/target=\"${id}\"/d" "$PROM_MERGED"
done

# 3. Merge failure counters (monotonic)
awk '
/fsbackup_runner_target_failures_total/ {
  key=$0
  sub(/[0-9]+$/, "", key)
  count[key] += $NF
  next
}
{ print }
END {
  for (k in count) print k count[k]
}
' "$PROM_MERGED" "$PROM_NEW" >"${PROM_MERGED}.new"

mv "${PROM_MERGED}.new" "$PROM_MERGED"

# 4. Append new metrics (snapshots + last_seen + exit_code)
cat "$PROM_NEW" >>"$PROM_MERGED"

# 5. Class-level metrics ONLY on full runs
if [[ "$RUN_SCOPE_FULL" -eq 1 ]]; then
  cat >>"$PROM_MERGED" <<EOF
fsbackup_runner_success{class="${CLASS}"} ${SUCCEEDED}
fsbackup_runner_failed{class="${CLASS}"} ${FAILED}
fsbackup_runner_last_exit_code{class="${CLASS}"} $([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)
EOF
fi

# 6. Always emit run scope
cat >>"$PROM_MERGED" <<EOF
fsbackup_runner_run_scope{class="${CLASS}"} ${RUN_SCOPE_FULL}
EOF

chgrp nodeexp_txt "$PROM_MERGED"
chmod 0640 "$PROM_MERGED"
mv "$PROM_MERGED" "$PROM_FILE"

rm -f "$PROM_NEW"

exit 0

