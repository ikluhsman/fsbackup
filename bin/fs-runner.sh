#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_SCRIPT="/usr/local/bin/fs-snapshot.sh"
CONFIG_FILE="/etc/fsbackup/targets.yml"

SNAPSHOT_TYPE="$1"
shift

CLASS=""
DRY_RUN=0
REPLACE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE=1; shift ;;
    *) shift ;;
  esac
done

[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

echo
echo "fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Targets:       ${#TARGETS[@]}"
echo "  Dry-run:       $DRY_RUN"
echo "  Replace:       $REPLACE"
echo

echo "Running preflight checks..."
if ! fs-doctor.sh --class "$CLASS" >/dev/null; then
  echo "Preflight failed — aborting snapshot run."
  exit 1
fi
echo

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  type="$(jq -r '.type // "dir"' <<<"$t")"

  echo "→ Target: $id"
  echo "  Host:   $host"
  echo "  Source: $src"

  cmd=(
    "$SNAPSHOT_SCRIPT"
    --target-id "$id"
    --class "$CLASS"
    --host "$host"
    --source "$src"
    --type "$type"
    --snapshot-type "$SNAPSHOT_TYPE"
  )

  [[ "$DRY_RUN" -eq 1 ]] && cmd+=(--dry-run)
  [[ "$REPLACE" -eq 1 ]] && cmd+=(--replace-existing)

  "${cmd[@]}" || true
  echo
done
