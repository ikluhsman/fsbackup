#!/usr/bin/env bash
set -u
# no set -e: runner must continue through failures

CONFIG_FILE="/etc/fsbackup/targets.yml"
SNAPSHOT_SCRIPT="/usr/local/sbin/fs-snapshot.sh"

CLASS=""
SNAPSHOT_TYPE="${1:-}"
shift || true

DRY_RUN=0
REPLACE_EXISTING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE_EXISTING=1; shift ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$SNAPSHOT_TYPE" && -n "$CLASS" ]] || exit 2

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

TOTAL=0
SUCCEEDED=0
FAILED=0
FAILED_TARGETS=()

echo
echo "fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Targets:       ${#TARGETS[@]}"
echo "  Dry-run:       $DRY_RUN"
echo "  Replace:       $REPLACE_EXISTING"
echo

echo "Running preflight checks..."
if ! sudo -u fsbackup fs-doctor.sh --class "$CLASS"; then
  echo
  echo "Preflight failed — aborting snapshot run."
  exit 1
fi
echo

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  type="$(jq -r '.type // "dir"' <<<"$t")"

  ((TOTAL++))

  echo "→ Target: $id"
  echo "  Host:   $host"
  echo "  Source: $src"
  echo "  Type:   $type"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  DRY-RUN"
    echo
    continue
  fi

  CMD=(
    "$SNAPSHOT_SCRIPT"
    --target-id "$id"
    --class "$CLASS"
    --host "$host"
    --source "$src"
    --snapshot-type "$SNAPSHOT_TYPE"
    --type "$type"
  )

  [[ "$REPLACE_EXISTING" -eq 1 ]] && CMD+=(--replace-existing)

  "${CMD[@]}"
  rc=$?

  if [[ "$rc" -eq 0 ]]; then
    ((SUCCEEDED++))
  else
    ((FAILED++))
    FAILED_TARGETS+=("$id")
  fi

  echo
done

echo "fs-runner summary"
echo "  Total targets: $TOTAL"
echo "  Succeeded:     $SUCCEEDED"
echo "  Failed:        $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo "  Failed targets:"
  printf "    - %s\n" "${FAILED_TARGETS[@]}"
fi

exit $([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)

