#!/usr/bin/env bash
set -u
set -o pipefail

. /etc/fsbackup/fsbackup.conf

CONFIG_FILE="/etc/fsbackup/targets.yml"

LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/backup.log"

NODE_TEXTFILE="/var/lib/node_exporter/textfile_collector"
PROM_OUT="${NODE_TEXTFILE}/fsbackup_excludes.prom"

BACKUP_SSH_USER="backup"
MAX_EXCLUDES=15

SNAPSHOT_TYPE="${1:-}"
shift || true

CLASS=""
DRY_RUN=0
REPLACE=0

usage() {
  echo "Usage: fs-runner.sh <daily|weekly|monthly> --class <class> [--dry-run] [--replace-existing]"
  exit 2
}

[[ "$SNAPSHOT_TYPE" =~ ^(daily|weekly|monthly)$ ]] || usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing|--replace) REPLACE=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$CLASS" ]] || usage

command -v yq >/dev/null || { echo "yq not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found"; exit 2; }
command -v ssh >/dev/null || { echo "ssh not found"; exit 2; }
command -v rsync >/dev/null || { echo "rsync not found"; exit 2; }

mkdir -p "$LOG_DIR"

log() {
  local id="$1"; shift
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) [$id] $*" | tee -a "$LOG_FILE" >/dev/null
}

is_local_host() {
  local h="$1"
  local short fqdn
  short="$(hostname -s)"
  fqdn="$(hostname -f 2>/dev/null || true)"

  [[ "$h" == "localhost" ]] && return 0
  [[ "$h" == "$short" ]] && return 0
  [[ -n "$fqdn" && "$h" == "$fqdn" ]] && return 0

  if getent hosts "$h" >/dev/null 2>&1; then
    local target_ips local_ips ip lip
    target_ips="$(getent hosts "$h" | awk '{print $1}')"
    local_ips="$(hostname -I 2>/dev/null || true)"
    for ip in $target_ips; do
      for lip in $local_ips; do
        [[ "$ip" == "$lip" ]] && return 0
      done
    done
  fi

  return 1
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5)

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

DATE_STR="$(date +%F)"
DEST_BASE="${SNAPSHOT_ROOT}/${SNAPSHOT_TYPE}/${DATE_STR}/${CLASS}"

echo
echo "fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Targets:       ${#TARGETS[@]}"
echo "  Dry-run:       $DRY_RUN"
echo "  Replace:       $REPLACE"
echo

mkdir -p "$DEST_BASE" || { echo "Cannot create destination: $DEST_BASE"; exit 2; }

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
    ssh "${SSH_OPTS[@]}" "${BACKUP_SSH_USER}@${host}" "test -e '$src'" \
      >/dev/null 2>&1 || { echo "→ $id FAIL (ssh/path)"; exit 1; }
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

PROM_TMP="$(mktemp)"

# Prometheus headers
cat >"$PROM_TMP" <<'EOF'
# HELP fsbackup_excludes_total Total auto-excluded paths for this target in this run
# TYPE fsbackup_excludes_total gauge
# HELP fsbackup_excludes_added_last_run Count of excludes added during retries for this target in this run
# TYPE fsbackup_excludes_added_last_run gauge
# HELP fsbackup_auto_exclude_used Whether auto-exclude logic was used (1=yes,0=no)
# TYPE fsbackup_auto_exclude_used gauge
EOF

for t in "${TARGETS[@]}"; do
  ((TOTAL++))
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$t")"

  DEST="${DEST_BASE}/${id}"
  mkdir -p "$DEST"

  log "$id" "Starting snapshot (${SNAPSHOT_TYPE}) from ${host}:${src}"

  RSYNC_CMD=(rsync -a --delete --timeout=30)
  [[ "$DRY_RUN" -eq 1 ]] && RSYNC_CMD+=(-n)
  [[ "$REPLACE" -eq 0 ]] && RSYNC_CMD+=(--ignore-existing)
  [[ -n "$rsync_opts" ]] && RSYNC_CMD+=($rsync_opts)

  EXCLUDE_FILE="$(mktemp)"
  : >"$EXCLUDE_FILE"

  EXCLUDES_ADDED=0
  AUTO_EXCLUDE_USED=0
  TOTAL_EXCLUDES=0

  while true; do
    rm -f rsync.err

    if is_local_host "$host"; then
      "${RSYNC_CMD[@]}" --exclude-from="$EXCLUDE_FILE" "${src%/}/" "$DEST/" 2>rsync.err && break
    else
      "${RSYNC_CMD[@]}" --exclude-from="$EXCLUDE_FILE" "${BACKUP_SSH_USER}@${host}:${src%/}/" "$DEST/" 2>rsync.err && break
    fi

    # find first permission-denied path (sender opendir)
    err_path="$(grep -oE 'opendir "([^"]+)" failed: Permission denied' rsync.err | sed -E 's/opendir "([^"]+)".*/\1/' | head -n1)"

    # If it wasn't the excludable error, stop retrying
    if [[ -z "$err_path" ]]; then
      break
    fi

    if (( TOTAL_EXCLUDES >= MAX_EXCLUDES )); then
      log "$id" "ERROR exclude ceiling reached (${MAX_EXCLUDES}). Last path: ${err_path}"
      FAILED=$((FAILED+1))
      rm -f rsync.err "$EXCLUDE_FILE"
      continue 2
    fi

    # Convert absolute path to relative-to-src where possible
    rel="$err_path"
    rel="${rel#${src%/}/}"
    rel="${rel#/}"

    echo "${rel}/**" >>"$EXCLUDE_FILE"
    log "$id" "WARN auto-excluding path: ${err_path}"

    ((TOTAL_EXCLUDES++))
    ((EXCLUDES_ADDED++))
    AUTO_EXCLUDE_USED=1
  done

  if [[ $? -eq 0 ]]; then
    log "$id" "Snapshot completed successfully"
    ((SUCCEEDED++))
  else
    log "$id" "ERROR snapshot failed (see rsync.err details during run)"
    ((FAILED++))
  fi

  cat >>"$PROM_TMP" <<EOF
fsbackup_excludes_total{target="${id}"} ${TOTAL_EXCLUDES}
fsbackup_excludes_added_last_run{target="${id}"} ${EXCLUDES_ADDED}
fsbackup_auto_exclude_used{target="${id}"} ${AUTO_EXCLUDE_USED}
EOF

  rm -f rsync.err "$EXCLUDE_FILE"
done

# Atomic write of prometheus metrics
tmp2="$(mktemp)"
cat "$PROM_TMP" >"$tmp2"
rm -f "$PROM_TMP"
mv "$tmp2" "$PROM_OUT" 2>/dev/null || rm -f "$tmp2"

echo
echo "fs-runner summary"
echo "  Total:     $TOTAL"
echo "  Succeeded: $SUCCEEDED"
echo "  Failed:    $FAILED"
echo

exit $([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)

