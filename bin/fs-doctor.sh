#!/usr/bin/env bash
set -u
set -o pipefail

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

CLASS=""

PRIMARY_ROOT="/backup/snapshots"
MIRROR_ROOT="/backup2/snapshots"

LOG_DIR="/var/lib/fsbackup/log"
ORPHAN_LOG="${LOG_DIR}/fs-orphans.log"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
ORPHAN_METRIC="${NODEEXP_DIR}/fsbackup_orphans.prom"
ANNUAL_IMMUTABLE_METRIC="${NODEEXP_DIR}/fsbackup_annual_immutable.prom"
NODEEXP_METRIC="${NODEEXP_DIR}/fsbackup_nodeexp_health.prom"

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
mkdir -p "$LOG_DIR"

for cmd in yq jq ssh; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found"; exit 2; }
done

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

# -----------------------------------------------------------------------------
# Target reachability checks
# -----------------------------------------------------------------------------
PASS=0
FAIL=0

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo "  Items:  ${#TARGETS[@]}"
echo

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

is_local_host() {
  [[ "$1" == "$(hostname -s)" || "$1" == "$(hostname -f 2>/dev/null)" || "$1" == "localhost" ]]
}

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"

  if is_local_host "$host"; then
    [[ -e "$src" ]] && { printf "%-28s OK     local path exists\n" "$id"; ((PASS++)); } \
                     || { printf "%-28s FAIL   local missing\n" "$id"; ((FAIL++)); }
  else
    ssh -o BatchMode=yes "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1 \
      && { printf "%-28s OK     ssh+path OK\n" "$id"; ((PASS++)); } \
      || { printf "%-28s FAIL   remote missing\n" "$id"; ((FAIL++)); }
  fi
done

echo
echo "Doctor summary"
echo "  OK:    $PASS"
echo "  FAIL:  $FAIL"
echo

# -----------------------------------------------------------------------------
# Orphan detection (PRIMARY + MIRROR, all tiers)
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$ORPHAN_LOG")"

mapfile -t VALID_IDS < <(
  yq eval '.. | select(has("id")) | .id' "$CONFIG_FILE" | sort -u
)

declare -A VALID
for id in "${VALID_IDS[@]}"; do VALID["$id"]=1; done

declare -A ORPHANS
for root in primary mirror; do
  for tier in daily weekly monthly annual; do
    ORPHANS["${root}_${tier}"]=0
  done
done

scan_root() {
  local root_label="$1"
  local base="$2"

  [[ -d "$base" ]] || return

  for tier in daily weekly monthly annual; do
    [[ -d "$base/$tier" ]] || continue

    find "$base/$tier" -mindepth 3 -maxdepth 3 -type d | while read -r d; do
      target="$(basename "$d")"
      class="$(basename "$(dirname "$d")")"
      date="$(basename "$(dirname "$(dirname "$d")")")"

      if [[ -z "${VALID[$target]+x}" ]]; then
        ORPHANS["${root_label}_${tier}"]=$((ORPHANS["${root_label}_${tier}"] + 1))
        echo "$(date -Is) root=${root_label} tier=${tier} date=${date} class=${class} orphan=${target}" >>"$ORPHAN_LOG"
      fi
    done
  done
}

scan_root primary "$PRIMARY_ROOT"
scan_root mirror  "$MIRROR_ROOT"

tmp="$(mktemp)"
{
  echo "# HELP fsbackup_orphan_snapshots_total Orphan snapshot directories by root and tier"
  echo "# TYPE fsbackup_orphan_snapshots_total gauge"
  for k in "${!ORPHANS[@]}"; do
    root="${k%%_*}"
    tier="${k##*_}"
    echo "fsbackup_orphan_snapshots_total{root=\"${root}\",tier=\"${tier}\"} ${ORPHANS[$k]}"
  done
} >"$tmp"

chgrp nodeexp_txt "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$ORPHAN_METRIC"

# -----------------------------------------------------------------------------
# Annual immutability audit
# -----------------------------------------------------------------------------
PRIMARY_ANNUAL="${PRIMARY_ROOT}/annual"
MIRROR_ANNUAL="${MIRROR_ROOT}/annual"

primary_ok=0
mirror_ok=0

[[ -d "$PRIMARY_ANNUAL" && ! -w "$PRIMARY_ANNUAL" ]] && primary_ok=1
[[ -d "$MIRROR_ANNUAL"  && ! -w "$MIRROR_ANNUAL"  ]] && mirror_ok=1

tmp="$(mktemp)"
cat >"$tmp" <<EOF
fsbackup_annual_immutable{root="primary"} ${primary_ok}
fsbackup_annual_immutable{root="mirror"} ${mirror_ok}
EOF

chgrp nodeexp_txt "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$ANNUAL_IMMUTABLE_METRIC"

# -----------------------------------------------------------------------------
# Node exporter health
# -----------------------------------------------------------------------------
nodeexp_ok=0
[[ -d "$NODEEXP_DIR" && -w "$NODEEXP_DIR" ]] && nodeexp_ok=1

tmp="$(mktemp)"
echo "fsbackup_node_exporter_textfile_access ${nodeexp_ok}" >"$tmp"
chgrp nodeexp_txt "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$NODEEXP_METRIC"

exit 0

