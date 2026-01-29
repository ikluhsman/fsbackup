#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# fsbackup_doctor.sh
#
# Run on the BACKUP HOST (fs). Diagnoses ssh/path/rsync readiness per targets.yml.
#
# Optional:
#   --seed-hostkeys  => ssh-keyscan all remote hosts into /var/lib/fsbackup/.ssh/known_hosts
#
# Writes a node_exporter metric (textfile collector) about doctor pass/fail.
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
  fsbackup_doctor.sh --class class2 [--seed-hostkeys]

Run as fsbackup user is ideal:
  sudo -u fsbackup ./fsbackup_doctor.sh --class class2 --seed-hostkeys
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --seed-hostkeys) SEED_HOSTKEYS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

command -v yq >/dev/null || { echo "yq not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found"; exit 2; }
command -v ssh >/dev/null || { echo "ssh not found"; exit 2; }
command -v rsync >/dev/null || { echo "rsync not found"; exit 2; }
command -v ssh-keyscan >/dev/null || { echo "ssh-keyscan not found"; exit 2; }

# Load targets as JSON objects (one per line)
mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

TOTAL="${#TARGETS[@]}"

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo "  Items:  $TOTAL"
echo

# Build unique host list (excluding local 'fs' and 'all')
declare -A HOSTS=()
for t in "${TARGETS[@]}"; do
  h="$(jq -r '.host' <<<"$t")"
  [[ -z "$h" || "$h" == "null" ]] && continue
  HOSTS["$h"]=1
done

KNOWN_HOSTS_FILE="/var/lib/fsbackup/.ssh/known_hosts"
mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
touch "$KNOWN_HOSTS_FILE"
chmod 600 "$KNOWN_HOSTS_FILE" || true

if [[ "$SEED_HOSTKEYS" -eq 1 ]]; then
  echo "Seeding SSH host keys (StrictHostKeyChecking friendly)..."
  for h in "${!HOSTS[@]}"; do
    # Skip local-ish and pseudo hosts
    if [[ "$h" == "fs" || "$h" == "all" ]]; then
      continue
    fi
    echo "  - $h"
    # Add both hostname + resolved key if possible. Ignore failures but report.
    ssh-keyscan -T 5 -t ed25519 "$h" 2>/dev/null >>"$KNOWN_HOSTS_FILE" || true
  done
  # De-dupe
  sort -u "$KNOWN_HOSTS_FILE" -o "$KNOWN_HOSTS_FILE" || true
  echo
fi

PASS=0
FAIL=0

# For cleaner output
printf "%-28s %-6s %-s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %-s\n" "----------------------------" "------" "------------------------------"

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  host="$(jq -r '.host // empty' <<<"$t")"
  src="$(jq -r '.source // empty' <<<"$t")"

  # Normalize empty/null
  [[ "$id" == "null" ]] && id=""
  [[ "$host" == "null" ]] && host=""
  [[ "$src" == "null" ]] && src=""

  if [[ -z "$id" || -z "$host" || -z "$src" ]]; then
    printf "%-28s %-6s %s\n" "${id:-<missing>}" "FAIL" "bad target entry (id/host/source)"
    ((FAIL++))
    continue
  fi

  if [[ "$host" == "fs" ]]; then
    # Local check
    if [[ -e "$src" ]]; then
      printf "%-28s %-6s %s\n" "$id" "OK" "local path exists"
      ((PASS++))
    else
      printf "%-28s %-6s %s\n" "$id" "FAIL" "local missing: $src"
      ((FAIL++))
    fi
    continue
  fi

  # Remote check: ssh basic + path probe + rsync dry-run listing
  # 1) SSH probe
  if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
      "${BACKUP_SSH_USER}@${host}" "echo ssh-ok" >/dev/null 2>&1; then
    printf "%-28s %-6s %s\n" "$id" "FAIL" "ssh failed"
    ((FAIL++))
    continue
  fi

  # 2) Path existence probe (use test -e, then attempt list/read)
  if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
      "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    printf "%-28s %-6s %s\n" "$id" "FAIL" "remote missing: $src"
    ((FAIL++))
    continue
  fi

  # 3) Rsync dry-run probe (this catches “protocol mismatch”, perms, nologin, etc.)
  # We rsync into a temp path but with -n nothing is written.
  if rsync -a -n --timeout=10 "${BACKUP_SSH_USER}@${host}:${src%/}/" "/tmp/fsbackup_doctor_${id//[^a-zA-Z0-9_.-]/_}" >/dev/null 2>&1; then
    printf "%-28s %-6s %s\n" "$id" "OK" "ssh+path+rsync dry-run OK"
    ((PASS++))
  else
    # Capture a short error string for operator
    err="$(rsync -a -n --timeout=10 "${BACKUP_SSH_USER}@${host}:${src%/}/" "/tmp/fsbackup_doctor_${id//[^a-zA-Z0-9_.-]/_}" 2>&1 | tail -n 1)"
    printf "%-28s %-6s %s\n" "$id" "FAIL" "rsync failed: ${err}"
    ((FAIL++))
  fi
done

echo
echo "Doctor summary"
echo "  Total: $TOTAL"
echo "  OK:    $PASS"
echo "  FAIL:  $FAIL"
echo

# Write Prometheus textfile metric
mkdir -p "$NODE_EXPORTER_TEXTFILE" || true
now="$(date +%s)"
cat >"$METRIC_FILE" <<EOF
# HELP fsbackup_doctor_last_run_seconds Unix timestamp of last doctor run
# TYPE fsbackup_doctor_last_run_seconds gauge
fsbackup_doctor_last_run_seconds ${now}

# HELP fsbackup_doctor_targets_total Total targets checked
# TYPE fsbackup_doctor_targets_total gauge
fsbackup_doctor_targets_total ${TOTAL}

# HELP fsbackup_doctor_targets_ok Targets passing doctor checks
# TYPE fsbackup_doctor_targets_ok gauge
fsbackup_doctor_targets_ok ${PASS}

# HELP fsbackup_doctor_targets_fail Targets failing doctor checks
# TYPE fsbackup_doctor_targets_fail gauge
fsbackup_doctor_targets_fail ${FAIL}

# HELP fsbackup_doctor_status Overall status (0=ok,1=has failures)
# TYPE fsbackup_doctor_status gauge
fsbackup_doctor_status $( [[ "$FAIL" -gt 0 ]] && echo 1 || echo 0 )
EOF

chmod 644 "$METRIC_FILE" 2>/dev/null || true

# Exit nonzero if failures
[[ "$FAIL" -eq 0 ]]


