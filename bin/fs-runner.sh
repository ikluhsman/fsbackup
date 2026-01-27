#!/usr/bin/env bash
set -u
# IMPORTANT: no set -e

CONFIG_FILE="/etc/fsbackup/targets.yml"
SNAPSHOT_SCRIPT="/usr/local/sbin/fs-snapshot.sh"

DRY_RUN=0
REPLACE_EXISTING=0
FAILED=0
SUCCEEDED=0
FAILED_TARGETS=()
PRECHECK=1

SNAPSHOT_TYPE="${1:-}"
shift || true
CLASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE_EXISTING=1; shift ;;
    --no-preflight) PRECHECK=0; shift;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done

[[ -n "$SNAPSHOT_TYPE" && -n "$CLASS" ]] || { echo "Missing args"; exit 2; }

PREFLIGHT_SCRIPT="/usr/local/sbin/fs-preflight.sh"

if [[ "$PRECHECK" -eq 1 ]]; then
  echo
  echo "Running preflight checks..."
  if ! "$PREFLIGHT_SCRIPT" "$CLASS"; then
    echo
    echo "Preflight failed — aborting snapshot run."
    exit 2
  fi
  echo "Preflight passed."
  echo
fi

command -v yq >/dev/null || { echo "yq missing"; exit 2; }
command -v jq >/dev/null || { echo "jq missing"; exit 2; }

TARGET_STREAM="$(yq eval -o=json ".${CLASS}" "$CONFIG_FILE" | jq -c '.[]')"
TOTAL="$(echo "$TARGET_STREAM" | wc -l)"

echo
echo "fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Targets:       $TOTAL"
echo "  Dry-run:       $DRY_RUN"
echo

while read -r target; do
  TARGET_ID="$(jq -r '.id' <<<"$target")"
  HOST="$(jq -r '.host' <<<"$target")"
  SOURCE="$(jq -r '.source' <<<"$target")"

  echo "→ Target: $TARGET_ID"
  echo "  Host:   $HOST"
  echo "  Source: $SOURCE"

  [[ "$DRY_RUN" -eq 1 ]] && continue

  CMD=(
    "$SNAPSHOT_SCRIPT"
    --target-id "$TARGET_ID"
    --class "$CLASS"
    --host "$HOST"
    --source "$SOURCE"
    --snapshot-type "$SNAPSHOT_TYPE"
  )

  [[ "$REPLACE_EXISTING" -eq 1 ]] && CMD+=(--replace-existing)

  if "${CMD[@]}"; then
    ((SUCCEEDED++))
  else
    ((FAILED++))
    FAILED_TARGETS+=("$TARGET_ID")
  fi

  echo
done <<<"$TARGET_STREAM"

echo "fs-runner summary"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Total targets: $TOTAL"
echo "  Succeeded:     $SUCCEEDED"
echo "  Failed:        $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo
  echo "  Failed targets:"
  for t in "${FAILED_TARGETS[@]}"; do
    echo "    - $t"
  done
fi

exit $([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)

