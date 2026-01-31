#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-runner.sh — snapshot executor with metrics
# =============================================================================

. /etc/fsbackup/fsbackup.conf

CONFIG_FILE="/etc/fsbackup/targets.yml"
LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/backup.log"

NODE_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PROM_TMP="$(mktemp)"
PROM_OUT="${NODE_TEXTFILE_DIR}/fsbackup_runner_${CLASS:-unknown}.prom"

BACKUP_SSH_USER="backup"
MAX_EXCLUDES=15

SNAPSHOT_TYPE="$1"   # daily | weekly | monthly
shift || true

CLASS=""
DRY_RUN=0
REPLACE=0

usage() {
  echo "Usage: fs-runner.sh <daily|weekly|monthly> --class <class> [--dry-run] [--replace-existing]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$CLASS" ]] || usage
mkdir -p "$LOG_DIR"

log() {
  local id="$1"; shift
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) [$id] $*" | tee -a "$LOG_FILE"
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

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

DATE_STR="$(date +%F)"
DEST_BASE="${SNAPSHOT_ROOT}/${SNAPSHOT_TYPE}/${DATE_STR}/${CLASS}"

echo "$(date +%Y-%m-%dT%H:%M:%S%z) fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Targets:       ${#TARGETS[@]}"
echo "  Dry-run:       $DRY_RUN"
echo "  Replace:       $REPLACE"
echo

# =============================================================================
# PREFLIGHT
# =============================================================================
echo "Running preflight checks..."

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
  echo "→ $id OK"
done

echo
echo "Preflight OK — executing snapshots"
echo

# =============================================================================
# EXECUTION
# =============================================================================
TOTAL=0
SUCCEEDED=0
FAILED=0

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

  log "$id" "Starting snapshot (${SNAPSHOT_TYPE}) from ${host}:${src}"

  RSYNC_CMD=(rsync -a --delete)

  [[ "$DRY_RUN" -eq 1 ]] && RSYNC_CMD+=(-n)
  [[ "$REPLACE" -eq 0 ]] && RSYNC_CMD+=(--ignore-existing)
  [[ -n "$rsync_opts" ]] && RSYNC_CMD+=($rsync_opts)

  TOTAL_EXCLUDES=0
  AUTO_EXCLUDE_USED=0

  while true; do
    if is_local_host "$host"; then
      "${RSYNC_CMD[@]}" \
        --exclude-from="$EXCLUDE_FILE" \
        "${src%/}/" "$DEST/" 2>"$RSYNC_ERR" && break
    else
      "${RSYNC_CMD[@]}" \
        --exclude-from="$EXCLUDE_FILE" \
        "${BACKUP_SSH_USER}@${host}:${src%/}/" "$DEST/" 2>"$RSYNC_ERR" && break
    fi

    err_path="$(grep -oE '/[^"]+' "$RSYNC_ERR" | head -n1)"

    [[ -z "$err_path" ]] && break

    if (( TOTAL_EXCLUDES >= MAX_EXCLUDES )); then
      log "$id" "ERROR exclude ceiling reached (${MAX_EXCLUDES}) at ${err_path}"
      ((FAILED++))
      continue 2
    fi

    echo "${err_path}/**" >>"$EXCLUDE_FILE"
    log "$id" "WARN auto-excluding path: ${err_path}"
    ((TOTAL_EXCLUDES++))
    AUTO_EXCLUDE_USED=1
  done

  rc=$?

  if [[ $rc -eq 0 ]]; then
    log "$id" "Snapshot completed successfully"
    ((SUCCEEDED++))

    NOW_EPOCH="$(date +%s)"
    SNAP_BYTES="$(du -sb "$DEST" 2>/dev/null | awk '{print $1}' || echo 0)"

    cat >>"$PROM_TMP" <<EOF
fsbackup_snapshot_last_success{class="${CLASS}",target="${id}"} ${NOW_EPOCH}
fsbackup_snapshot_bytes{class="${CLASS}",target="${id}"} ${SNAP_BYTES}
fsbackup_excludes_total{class="${CLASS}",target="${id}"} ${TOTAL_EXCLUDES}
fsbackup_auto_exclude_used{class="${CLASS}",target="${id}"} ${AUTO_EXCLUDE_USED}
EOF
  else
    log "$id" "ERROR snapshot failed"
    ((FAILED++))
  fi

  rm -f "$RSYNC_ERR" "$EXCLUDE_FILE"
done

# =============================================================================
# RUN-LEVEL METRICS
# =============================================================================
EXIT_CODE=0
[[ "$FAILED" -gt 0 ]] && EXIT_CODE=1

cat >>"$PROM_TMP" <<EOF
fsbackup_runner_success{class="${CLASS}"} ${SUCCEEDED}
fsbackup_runner_failed{class="${CLASS}"} ${FAILED}
fsbackup_runner_last_exit_code{class="${CLASS}"} ${EXIT_CODE}
EOF

mv "$PROM_TMP" "${NODE_TEXTFILE_DIR}/fsbackup_runner_${CLASS}.prom"
echo
echo "fs-runner summary"
echo "  Total:     $TOTAL"
echo "  Succeeded: $SUCCEEDED"
echo "  Failed:    $FAILED"
echo

exit "$EXIT_CODE"

