#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${NODE_EXPORTER_TEXTFILE}/fsbackup_doctor.prom"

CLASS=""
SEED_HOSTKEYS=0

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

command -v yq >/dev/null
command -v jq >/dev/null
command -v ssh >/dev/null
command -v rsync >/dev/null
command -v ssh-keyscan >/dev/null

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
  [[ -n "$h" && "$h" != "fs" ]] && HOSTS["$h"]=1
done

KNOWN_HOSTS_FILE="/var/lib/fsbackup/.ssh/known_hosts"
mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
touch "$KNOWN_HOSTS_FILE"
chmod 600 "$KNOWN_HOSTS_FILE"

if [[ "$SEED_HOSTKEYS" -eq 1 ]]; then
  echo "Seeding SSH host keys..."
  for h in "${!HOSTS[@]}"; do
    ssh-keyscan -T 5 -t ed25519 "$h" 2>/dev/null >>"$KNOWN_HOSTS_FILE" || true
  done
  sort -u "$KNOWN_HOSTS_FILE" -o "$KNOWN_HOSTS_FILE"
  echo
fi

PASS=0
FAIL=0

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  type="$(jq -r '.type // "dir"' <<<"$t")"

  if [[ "$host" == "fs" ]]; then
    if [[ -e "$src" ]]; then
      printf "%-28s %-6s local path exists\n" "$id" "OK"
      ((PASS++))
    else
      printf "%-28s %-6s local missing: %s\n" "$id" "FAIL" "$src"
      ((FAIL++))
    fi
    continue
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${BACKUP_SSH_USER}@${host}" "true" >/dev/null 2>&1; then
    printf "%-28s %-6s ssh failed\n" "$id" "FAIL"
    ((FAIL++))
    continue
  fi

  if ! ssh "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    printf "%-28s %-6s remote missing: %s\n" "$id" "FAIL" "$src"
    ((FAIL++))
    continue
  fi

  if [[ "$type" == "file" ]]; then
    RSYNC_SRC="${BACKUP_SSH_USER}@${host}:${src}"
  else
    RSYNC_SRC="${BACKUP_SSH_USER}@${host}:${src%/}/"
  fi

  if rsync -a -n "$RSYNC_SRC" "/tmp/fsdoctor_${id}" >/dev/null 2>&1; then
    printf "%-28s %-6s ssh+path+rsync dry-run OK\n" "$id" "OK"
    ((PASS++))
  else
    err="$(rsync -a -n "$RSYNC_SRC" "/tmp/fsdoctor_${id}" 2>&1 | tail -n 1)"
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

mkdir -p "$NODE_EXPORTER_TEXTFILE"
now="$(date +%s)"

cat >"$METRIC_FILE" <<EOF
fsbackup_doctor_last_run_seconds $now
fsbackup_doctor_targets_total $TOTAL
fsbackup_doctor_targets_ok $PASS
fsbackup_doctor_targets_fail $FAIL
fsbackup_doctor_status $( [[ "$FAIL" -gt 0 ]] && echo 1 || echo 0 )
EOF

chmod 644 "$METRIC_FILE"
[[ "$FAIL" -eq 0 ]]

