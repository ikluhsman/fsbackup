#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-doctor.sh
#
# Run on the BACKUP HOST (fs). Diagnoses ssh/path/rsync readiness per targets.yml.
#
# Optional:
#   --seed-hostkeys  => ssh-keyscan all remote hosts into fsbackup known_hosts
#
# Writes node_exporter textfile metrics.
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${NODE_EXPORTER_TEXTFILE}/fsbackup_doctor.prom"

CLASS=""
SEED_HOSTKEYS=0

usage() {
  cat <<'EOF'
Usage:
  fs-doctor.sh --class <class> [--seed-hostkeys]

Example:
  sudo -u fsbackup fs-doctor.sh --class class2 --seed-hostkeys
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --seed-hostkeys) SEED_HOSTKEYS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

command -v yq >/dev/null || exit 2
command -v jq >/dev/null || exit 2
command -v ssh >/dev/null || exit 2
command -v rsync >/dev/null || exit 2
command -v ssh-keyscan >/dev/null || exit 2

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

TOTAL="${#TARGETS[@]}"

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo "  Items:  $TOTAL"
echo

declare -A HOSTS=()
for t in "${TARGETS[@]}"; do
  h="$(jq -r '.host // empty' <<<"$t")"
  [[ -n "$h" && "$h" != "fs" && "$h" != "all" ]] && HOSTS["$h"]=1
done

KNOWN_HOSTS="/var/lib/fsbackup/.ssh/known_hosts"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

if [[ "$SEED_HOSTKEYS" -eq 1 ]]; then
  echo "Seeding SSH host keys..."
  for h in "${!HOSTS[@]}"; do
    ssh-keyscan -T 5 -t ed25519 "$h" 2>/dev/null >>"$KNOWN_HOSTS" || true
  done
  sort -u "$KNOWN_HOSTS" -o "$KNOWN_HOSTS"
  echo
fi

PASS=0
FAIL=0

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  host="$(jq -r '.host // empty' <<<"$t")"
  src="$(jq -r '.source // empty' <<<"$t")"
  type="$(jq -r '.type // "dir"' <<<"$t")"

  if [[ -z "$id" || -z "$host" || -z "$src" ]]; then
    printf "%-28s %-6s bad target entry\n" "${id:-<missing>}" "FAIL"
    ((FAIL++))
    continue
  fi

  if [[ "$type" != "file" && "$type" != "dir" ]]; then
    printf "%-28s %-6s invalid type '%s'\n" "$id" "FAIL" "$type"
    ((FAIL++))
    continue
  fi

  if [[ "$host" == "fs" ]]; then
    [[ -e "$src" ]] \
      && { printf "%-28s %-6s local path exists\n" "$id" "OK"; ((PASS++)); } \
      || { printf "%-28s %-6s local missing\n" "$id" "FAIL"; ((FAIL++)); }
    continue
  fi

  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
      "${BACKUP_SSH_USER}@${host}" "true" >/dev/null 2>&1 \
    || { printf "%-28s %-6s ssh failed\n" "$id" "FAIL"; ((FAIL++)); continue; }

  ssh "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1 \
    || { printf "%-28s %-6s remote missing\n" "$id" "FAIL"; ((FAIL++)); continue; }

  if [[ "$type" == "file" ]]; then
    RSYNC_SRC="${BACKUP_SSH_USER}@${host}:${src}"
    [[ "$src" == */ ]] && {
      printf "%-28s %-6s type=file but trailing slash\n" "$id" "FAIL"
      ((FAIL++))
      continue
    }
  else
    RSYNC_SRC="${BACKUP_SSH_USER}@${host}:${src%/}/"
  fi

  if rsync -a -n --timeout=10 "$RSYNC_SRC" "/tmp/fsdoctor_${id}" >/dev/null 2>&1; then
    printf "%-28s %-6s ssh+path+rsync dry-run OK\n" "$id" "OK"
    ((PASS++))
  else
    err="$(rsync -a -n --timeout=10 "$RSYNC_SRC" "/tmp/fsdoctor_${id}" 2>&1 | tail -n 1)"
    printf "%-28s %-6s rsync failed: %s\n" "$id" "FAIL" "$err"
    ((FAIL++))
  fi
done

echo
echo "Doctor summary"
echo "  Total: $TOTAL"
echo "  OK:    $PASS"
echo "  FAIL:  $FAIL"
echo

now="$(date +%s)"
cat >"$METRIC_FILE" <<EOF
fsbackup_doctor_last_run_seconds $now
fsbackup_doctor_targets_total $TOTAL
fsbackup_doctor_targets_ok $PASS
fsbackup_doctor_targets_fail $FAIL
fsbackup_doctor_status $([[ "$FAIL" -gt 0 ]] && echo 1 || echo 0)
EOF

chmod 644 "$METRIC_FILE" || true
[[ "$FAIL" -eq 0 ]]

