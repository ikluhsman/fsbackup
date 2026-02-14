#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-runner.sh — deterministic snapshot executor (no metric duplication)
# =============================================================================

. /etc/fsbackup/fsbackup.conf

CONFIG_FILE="/etc/fsbackup/targets.yml"
LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/backup.log"
NODE_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

BACKUP_SSH_USER="backup"
MAX_EXCLUDES=15

SNAPSHOT_TYPE="$1"
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
NOW_EPOCH="$(date +%s)"
RUN_SCOPE_FULL=1
[[ -n "$TARGET_FILTER" ]] && RUN_SCOPE_FULL=0

log() {
  local id="$1"; shift
  echo "$(date -Is) [$id] $*" | tee -a "$LOG_FILE"
}

is_local_host() {
  local h="$1"
  [[ "$h" == "localhost" ]] && return 0
  [[ "$h" == "$(hostname -s)" ]] && return 0
  [[ "$h" == "$(hostname -f 2>/dev/null)" ]] && return 0
  return 1
}

# -----------------------------------------------------------------------------
# Load targets
# -----------------------------------------------------------------------------

if [[ -n "$TARGET_FILTER" ]]; then
  mapfile -t TARGETS < <(
    yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c "select(.id == \"${TARGET_FILTER}\")"
  )
else
  mapfile -t TARGETS < <(
    yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
  )
fi

[[ "${#TARGETS[@]}" -eq 0 ]] && {
  echo "No targets found."
  exit 2
}

DATE_STR="$(date +%F)"
DEST_BASE="${SNAPSHOT_ROOT}/${SNAPSHOT_TYPE}/${DATE_STR}/${CLASS}"

echo "$(date -Is) fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Target filter: ${TARGET_FILTER:-<none>}"
echo

# -----------------------------------------------------------------------------
# Load existing failure counters
# -----------------------------------------------------------------------------

declare -A FAILURE_COUNTERS

if [[ -f "$PROM_FILE" ]]; then
  while read -r line; do
    if [[ "$line" =~ fsbackup_runner_target_failures_total ]]; then
      target=$(echo "$line" | sed -n 's/.*target="\([^"]*\)".*/\1/p')
      value=$(echo "$line" | awk '{print $NF}')
      FAILURE_COUNTERS["$target"]="$value"
    fi
  done < "$PROM_FILE"
fi

# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------

TOTAL=0
SUCCEEDED=0
FAILED=0

PROM_TMP="$(mktemp)"

for t in "${TARGETS[@]}"; do
  ((TOTAL++))

  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$t")"

  DEST="${DEST_BASE}/${id}"
  mkdir -p "$DEST"

  log "$id" "Starting snapshot"

  RSYNC_CMD=(rsync -a --delete)
  [[ "$DRY_RUN" -eq 1 ]] && RSYNC_CMD+=(-n)
  [[ "$REPLACE" -eq 0 ]] && RSYNC_CMD+=(--ignore-existing)
  [[ -n "$rsync_opts" ]] && RSYNC_CMD+=($rsync_opts)

  if is_local_host "$host"; then
    "${RSYNC_CMD[@]}" "${src%/}/" "$DEST/"
  else
    "${RSYNC_CMD[@]}" "${BACKUP_SSH_USER}@${host}:${src%/}/" "$DEST/"
  fi

  rc=$?

  if [[ $rc -eq 0 ]]; then
    ((SUCCEEDED++))
    SNAP_BYTES="$(du -sb "$DEST" 2>/dev/null | awk '{print $1}' || echo 0)"

    cat >>"$PROM_TMP" <<EOF
fsbackup_snapshot_last_success{class="${CLASS}",target="${id}"} ${NOW_EPOCH}
fsbackup_snapshot_bytes{class="${CLASS}",target="${id}"} ${SNAP_BYTES}
fsbackup_runner_target_last_seen{class="${CLASS}",target="${id}"} ${NOW_EPOCH}
fsbackup_runner_target_last_exit_code{class="${CLASS}",target="${id}"} 0
EOF

    FAILURE_COUNTERS["$id"]="${FAILURE_COUNTERS["$id"]:-0}"

  else
    ((FAILED++))
    FAILURE_COUNTERS["$id"]=$(( ${FAILURE_COUNTERS["$id"]:-0} + 1 ))

    cat >>"$PROM_TMP" <<EOF
fsbackup_snapshot_last_failure{class="${CLASS}",target="${id}"} ${NOW_EPOCH}
fsbackup_runner_target_last_seen{class="${CLASS}",target="${id}"} ${NOW_EPOCH}
fsbackup_runner_target_last_exit_code{class="${CLASS}",target="${id}"} ${rc}
EOF
  fi

done

# -----------------------------------------------------------------------------
# Emit monotonic failure counters
# -----------------------------------------------------------------------------

for target in "${!FAILURE_COUNTERS[@]}"; do
  echo "fsbackup_runner_target_failures_total{class=\"${CLASS}\",target=\"${target}\"} ${FAILURE_COUNTERS[$target]}" >>"$PROM_TMP"
done

# -----------------------------------------------------------------------------
# Class-level metrics
# -----------------------------------------------------------------------------

if [[ "$RUN_SCOPE_FULL" -eq 1 ]]; then
  cat >>"$PROM_TMP" <<EOF
fsbackup_runner_success{class="${CLASS}"} ${SUCCEEDED}
fsbackup_runner_failed{class="${CLASS}"} ${FAILED}
fsbackup_runner_last_exit_code{class="${CLASS}"} $([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)
EOF
fi

echo "fsbackup_runner_run_scope{class=\"${CLASS}\"} ${RUN_SCOPE_FULL}" >>"$PROM_TMP"

# -----------------------------------------------------------------------------
# Write atomically
# -----------------------------------------------------------------------------

chgrp nodeexp_txt "$PROM_TMP"
chmod 0640 "$PROM_TMP"
mv "$PROM_TMP" "$PROM_FILE"

# -----------------------------------------------------------------------------
# Class exit marker
# -----------------------------------------------------------------------------

mkdir -p "$DEST_BASE"
CLASS_EXIT=$([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)
echo "$CLASS_EXIT" > "${DEST_BASE}/.fsbackup_class_exit_code"

exit 0

