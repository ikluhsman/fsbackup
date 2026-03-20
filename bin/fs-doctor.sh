#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-doctor.sh — target health + snapshot audit + immutability verification
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

CLASS=""

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
NODEEXP_METRIC="${NODEEXP_DIR}/fsbackup_nodeexp_health.prom"
ORPHAN_METRIC="${NODEEXP_DIR}/fsbackup_orphans.prom"
IMMUTABLE_METRIC="${NODEEXP_DIR}/fsbackup_annual_immutable.prom"

ORPHAN_LOG="/var/lib/fsbackup/log/fs-orphans.log"
IMMUTABLE_LOG="/var/lib/fsbackup/log/fs-immutable.log"

PRIMARY_SNAPSHOT_ROOT="/backup/snapshots"
MIRROR_SNAPSHOT_ROOT="/backup2/snapshots"

usage() {
  echo "Usage: fs-doctor.sh --class <class>"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$CLASS" ]] || usage

START_TS=$(date +%s.%N)

for cmd in yq jq ssh; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found"; exit 2; }
done

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

is_local_host() {
  local h="$1"
  [[ "$h" == "localhost" || "$h" == "$(hostname -s)" || "$h" == "$(hostname -f 2>/dev/null)" ]] && return 0
  getent hosts "$h" >/dev/null 2>&1 || return 1
  for ip in $(getent hosts "$h" | awk '{print $1}'); do
    hostname -I | grep -qw "$ip" && return 0
  done
  return 1
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5)

PASS=0
FAIL=0
WARN=0

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

# -----------------------------------------------------------------------------
# TARGET HEALTH
# -----------------------------------------------------------------------------
for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  host="$(jq -r '.host // empty' <<<"$t")"
  src="$(jq -r '.source // empty' <<<"$t")"

  if [[ -z "$id" || -z "$host" || -z "$src" ]]; then
    printf "%-28s %-6s %s\n" "${id:-<unknown>}" "WARN" "invalid target entry"
    ((WARN++))
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

  if ssh "${SSH_OPTS[@]}" "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    printf "%-28s %-6s %s\n" "$id" "OK" "ssh+path OK"
    ((PASS++))
  else
    printf "%-28s %-6s %s\n" "$id" "FAIL" "ssh/path failed"
    ((FAIL++))
  fi
done

echo
echo "Doctor summary"
echo "  OK:    $PASS"
echo "  WARN:  $WARN"
echo "  FAIL:  $FAIL"
echo

# -----------------------------------------------------------------------------
# ORPHAN DETECTION
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$ORPHAN_LOG")"

mapfile -t VALID_IDS < <(
  yq eval '.. | select(has("id")) | .id' "$CONFIG_FILE" | sort -u
)

declare -A VALID
for id in "${VALID_IDS[@]}"; do VALID["$id"]=1; done

declare -A ORPHANS=(["primary"]=0 ["mirror"]=0)

scan_root() {
  local root="$1"
  local label="$2"

  [[ -d "$root" ]] || return 0

  while read -r d; do
    target="$(basename "$d")"
    class="$(basename "$(dirname "$d")")"
    tier="$(basename "$(dirname "$(dirname "$d")")")"
    date="$(basename "$(dirname "$(dirname "$(dirname "$d")")")")"

    if [[ -z "${VALID[$target]+x}" ]]; then
      ORPHANS["$label"]=$((ORPHANS["$label"] + 1))
      echo "$(date -Is) root=${label} tier=${tier} date=${date} class=${class} orphan=${target}" >>"$ORPHAN_LOG"
    fi
  done < <(find "$root" -mindepth 3 -maxdepth 4 -type d)
}

scan_root "$PRIMARY_SNAPSHOT_ROOT" "primary"
scan_root "$MIRROR_SNAPSHOT_ROOT" "mirror"

tmp="$(mktemp)"
cat >"$tmp" <<EOF
fsbackup_orphan_snapshots_total{root="primary"} ${ORPHANS[primary]}
fsbackup_orphan_snapshots_total{root="mirror"} ${ORPHANS[mirror]}
EOF
chgrp nodeexp_txt "$tmp" 2>/dev/null || true
chmod 0644 "$tmp"
mv "$tmp" "$ORPHAN_METRIC"

# -----------------------------------------------------------------------------
# 🔒 ANNUAL IMMUTABILITY VERIFICATION
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$IMMUTABLE_LOG")"

PRIMARY_IMMUTABLE=1
MIRROR_IMMUTABLE=1

check_annual() {
  local root="$1"
  local label="$2"

  local annual_root="${root}/annual"
  [[ -d "$annual_root" ]] || return 0

  while read -r d; do
    if [[ -w "$d" ]]; then
      echo "$(date -Is) root=${label} writable=${d}" >>"$IMMUTABLE_LOG"
      [[ "$label" == "primary" ]] && PRIMARY_IMMUTABLE=0
      [[ "$label" == "mirror" ]] && MIRROR_IMMUTABLE=0
    fi
  done < <(find "$annual_root" -type d)
}

check_annual "$PRIMARY_SNAPSHOT_ROOT" "primary"
check_annual "$MIRROR_SNAPSHOT_ROOT" "mirror"

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_annual_immutable Whether annual snapshots are immutable (1=yes,0=no)
# TYPE fsbackup_annual_immutable gauge
fsbackup_annual_immutable{root="primary"} ${PRIMARY_IMMUTABLE}
fsbackup_annual_immutable{root="mirror"} ${MIRROR_IMMUTABLE}
EOF
chgrp nodeexp_txt "$tmp" 2>/dev/null || true
chmod 0644 "$tmp"
mv "$tmp" "$IMMUTABLE_METRIC"

END_TS=$(date +%s.%N)
DURATION=$(awk "BEGIN {print $END_TS - $START_TS}")

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_doctor_duration_seconds Duration of fsbackup doctor run
# TYPE fsbackup_doctor_duration_seconds gauge
fsbackup_doctor_duration_seconds{class="$CLASS"} ${DURATION}
EOF
chgrp nodeexp_txt "$tmp" 2>/dev/null || true
chmod 0644 "$tmp"
mv "$tmp" "${NODEEXP_DIR}/fsbackup_doctor_duration.prom"

exit 0

