#!/usr/bin/env bash
set -u
set -o pipefail

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

CLASS=""
SEED_HOSTKEYS=0

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
NODEEXP_METRIC="${NODEEXP_DIR}/fsbackup_nodeexp_health.prom"
ORPHAN_METRIC="${NODEEXP_DIR}/fsbackup_orphans.prom"

ORPHAN_LOG="/var/lib/fsbackup/log/fs-orphans.log"
SNAPSHOT_ROOT="/backup/snapshots"

usage() {
  echo "Usage: fs-doctor.sh --class <class> [--seed-hostkeys]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --seed-hostkeys) SEED_HOSTKEYS=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

command -v yq >/dev/null || { echo "yq not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found"; exit 2; }
command -v ssh >/dev/null || { echo "ssh not found"; exit 2; }
command -v rsync >/dev/null || { echo "rsync not found"; exit 2; }
command -v ssh-keyscan >/dev/null || { echo "ssh-keyscan not found"; exit 2; }

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

is_local_host() {
  local h="$1"

  local short fqdn
  short="$(hostname -s)"
  fqdn="$(hostname -f 2>/dev/null || true)"

  [[ "$h" == "localhost" ]] && return 0
  [[ "$h" == "$short" ]] && return 0
  [[ -n "$fqdn" && "$h" == "$fqdn" ]] && return 0

  if getent hosts "$h" >/dev/null 2>&1; then
    local target_ips local_ips
    target_ips="$(getent hosts "$h" | awk '{print $1}')"
    local_ips="$(hostname -I 2>/dev/null || true)"

    local ip lip
    for ip in $target_ips; do
      for lip in $local_ips; do
        [[ "$ip" == "$lip" ]] && return 0
      done
    done
  fi

  return 1
}

is_excludable_rsync_error() {
  grep -qE 'rsync: \[sender\] opendir ".+" failed: Permission denied \(13\)' <<<"$1"
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5)

TOTAL="${#TARGETS[@]}"
PASS=0
FAIL=0

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo "  Items:  $TOTAL"
echo

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  host="$(jq -r '.host // empty' <<<"$t")"
  src="$(jq -r '.source // empty' <<<"$t")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$t")"

  if [[ -z "$id" || -z "$host" || -z "$src" ]]; then
    printf "%-28s %-6s %s\n" "${id:-<missing>}" "FAIL" "bad target entry"
    ((FAIL++))
    continue
  fi

  if is_local_host "$host"; then
    if [[ -e "$src" ]]; then
      printf "%-28s %-6s %s\n" "$id" "OK" "local path exists"
      ((PASS++))
    else
      printf "%-28s %-6s %s\n" "$id" "FAIL" "local missing: $src"
      ((FAIL++))
    fi
    continue
  fi

  if ! ssh "${SSH_OPTS[@]}" "${BACKUP_SSH_USER}@${host}" "echo ok" >/dev/null 2>&1; then
    printf "%-28s %-6s %s\n" "$id" "FAIL" "ssh failed"
    ((FAIL++))
    continue
  fi

  if ! ssh "${SSH_OPTS[@]}" "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    printf "%-28s %-6s %s\n" "$id" "FAIL" "remote missing: $src"
    ((FAIL++))
    continue
  fi

  RSYNC_CMD=(rsync -a -n --timeout=10)
  [[ -n "$rsync_opts" ]] && RSYNC_CMD+=($rsync_opts)

  RSYNC_ERR="$("${RSYNC_CMD[@]}" \
    "${BACKUP_SSH_USER}@${host}:${src%/}/" \
    "/tmp/fsdoctor_${id//[^a-zA-Z0-9_.-]/_}" \
    >/dev/null 2>&1
  )"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    printf "%-28s %-6s %s\n" "$id" "OK" "ssh+path+rsync dry-run OK"
    ((PASS++))
  elif is_excludable_rsync_error "$RSYNC_ERR"; then
    printf "%-28s %-6s %s\n" "$id" "WARN" "rsync permission-denied (auto-excludable)"
    ((PASS++))
  else
    printf "%-28s %-6s %s\n" "$id" "FAIL" "rsync failed"
    ((FAIL++))
  fi
done

echo
echo "Doctor summary"
echo "  Total: $TOTAL"
echo "  OK:    $PASS"
echo "  FAIL:  $FAIL"
echo

# -----------------------------------------------------------------------------
# Node exporter textfile collector health
# -----------------------------------------------------------------------------
nodeexp_ok=0
if [[ -d "$NODEEXP_DIR" && -r "$NODEEXP_DIR" && -x "$NODEEXP_DIR" ]]; then
  nodeexp_ok=1
fi

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_node_exporter_textfile_access Whether fsbackup can read the node_exporter textfile collector dir (1=ok,0=bad)
# TYPE fsbackup_node_exporter_textfile_access gauge
fsbackup_node_exporter_textfile_access ${nodeexp_ok}
EOF
mv "$tmp" "$NODEEXP_METRIC" 2>/dev/null || rm -f "$tmp"

# -----------------------------------------------------------------------------
# Orphan snapshot detection (Option A — global scan)
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$ORPHAN_LOG")"

mapfile -t VALID_TARGET_IDS < <(
  yq eval '.. | select(has("id")) | .id' "$CONFIG_FILE" | sort -u
)

declare -A VALID_MAP
for id in "${VALID_TARGET_IDS[@]}"; do
  VALID_MAP["$id"]=1
done

declare -A ORPHAN_COUNT=(["daily"]=0 ["weekly"]=0 ["monthly"]=0)

now="$(date -Is)"

for tier in daily weekly monthly; do
  tier_dir="${SNAPSHOT_ROOT}/${tier}"
  [[ -d "$tier_dir" ]] || continue

  while IFS= read -r snapshot_dir; do
    target_id="$(basename "$snapshot_dir")"
    class="$(basename "$(dirname "$snapshot_dir")")"
    SNAP_DATE="$(basename "$(dirname "$(dirname "$snapshot_dir")")")"

    if [[ -z "${VALID_MAP[$target_id]+x}" ]]; then
      ORPHAN_COUNT["$tier"]=$((ORPHAN_COUNT["$tier"] + 1))
      echo "${now} tier=${tier} date=${SNAP_DATE} class=${class} orphan=${target_id}" >>"$ORPHAN_LOG"
    fi
  done < <(
    find "$tier_dir" -mindepth 3 -maxdepth 3 -type d
  )
done


tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_orphan_snapshots_total Number of orphaned snapshot targets by tier
# TYPE fsbackup_orphan_snapshots_total gauge
fsbackup_orphan_snapshots_total{tier="daily"}   ${ORPHAN_COUNT[daily]}
fsbackup_orphan_snapshots_total{tier="weekly"}  ${ORPHAN_COUNT[weekly]}
fsbackup_orphan_snapshots_total{tier="monthly"} ${ORPHAN_COUNT[monthly]}
EOF

mv "$tmp" "$ORPHAN_METRIC" 2>/dev/null || rm -f "$tmp"

exit 0

