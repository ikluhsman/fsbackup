#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-runner.sh
#
# Orchestrates snapshot runs for all targets in a class.
# Requires yq v4 and jq.
#
# Usage:
#   fs-runner.sh <snapshot-type> --class <class> [--dry-run]
#
# Example:
#   fs-runner.sh daily --class class2 --dry-run
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
SNAPSHOT_BIN="/usr/local/sbin/fs-snapshot.sh"

SNAPSHOT_TYPE=""
CLASS=""
DRY_RUN=0

# -----------------------------
# Argument parsing
# -----------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: fs-runner.sh <snapshot-type> --class <class> [--dry-run]" >&2
  exit 2
fi

SNAPSHOT_TYPE="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)
      CLASS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# -----------------------------
# Validation
# -----------------------------
case "$SNAPSHOT_TYPE" in
  daily|weekly|monthly|annual) ;;
  *)
    echo "Invalid snapshot type: $SNAPSHOT_TYPE" >&2
    exit 2
    ;;
esac

if [[ -z "$CLASS" ]]; then
  echo "Missing --class" >&2
  exit 2
fi

if [[ ! -x "$SNAPSHOT_BIN" ]]; then
  echo "Snapshot script not found or not executable: $SNAPSHOT_BIN" >&2
  exit 1
fi

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "Cannot read config file: $CONFIG_FILE" >&2
  exit 1
fi

command -v yq >/dev/null || {
  echo "yq not found (v4 required)" >&2
  exit 1
}

command -v jq >/dev/null || {
  echo "jq not found" >&2
  exit 1
}

# -----------------------------
# Ensure class exists (yq v4)
# -----------------------------
if [[ "$(yq ".${CLASS} == null" "$CONFIG_FILE")" == "true" ]]; then
  echo "Class not found in targets.yml: $CLASS" >&2
  exit 1
fi

TARGET_COUNT="$(yq ".${CLASS} | length" "$CONFIG_FILE")"

if [[ "$TARGET_COUNT" -eq 0 ]]; then
  echo "No targets defined for class: $CLASS"
  exit 0
fi

# -----------------------------
# Banner
# -----------------------------
echo
echo "fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Targets:       $TARGET_COUNT"
echo "  Dry-run:       $DRY_RUN"
echo

# -----------------------------
# Iterate targets
# -----------------------------
yq ".${CLASS}[]" "$CONFIG_FILE" | jq -c '.' | while read -r target; do
  TARGET_ID="$(jq -r '.id' <<<"$target")"
  HOST="$(jq -r '.host' <<<"$target")"
  SOURCE="$(jq -r '.source' <<<"$target")"

  echo "→ Target: $TARGET_ID"
  echo "  Host:   $HOST"
  echo "  Source: $SOURCE"

  CMD=(
    "$SNAPSHOT_BIN"
    --target-id "$TARGET_ID"
    --class "$CLASS"
    --host "$HOST"
    --snapshot-type "$SNAPSHOT_TYPE"
    --source "$SOURCE"
  )

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  DRY-RUN:"
    echo "    ${CMD[*]}"
    echo
    continue
  fi

  "${CMD[@]}"
  echo
done

echo "fs-runner completed successfully"
echo

