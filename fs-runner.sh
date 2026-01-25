#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-runner.sh
#
# Reads targets.yml and executes fs-snapshot.sh for matching snapshot types.
# =============================================================================

CONFIG="/etc/fsbackup/targets.yml"
SNAPSHOT_TYPE="${1:-}"

if [[ -z "$SNAPSHOT_TYPE" ]]; then
  echo "Usage: fs-runner.sh <daily|weekly|monthly|annual>" >&2
  exit 2
fi

command -v yq >/dev/null 2>&1 || {
  echo "ERROR: yq is required" >&2
  exit 1
}

for CLASS in $(yq e 'keys | .[]' "$CONFIG"); do
  yq e ".${CLASS}[]" "$CONFIG" | while read -r _; do
    ID="$(yq e '.id' - <<<"$_")"
    HOST="$(yq e '.host' - <<<"$_")"
    SOURCE="$(yq e '.source' - <<<"$_")"
    SNAP="$(yq e '.snapshot' - <<<"$_")"

    if [[ "$SNAP" != "$SNAPSHOT_TYPE" ]]; then
      continue
    fi

    echo "Running snapshot for ${ID}"

    fs-snapshot.sh \
      --target-id "$ID" \
      --class "$CLASS" \
      --host "$HOST" \
      --snapshot-type "$SNAPSHOT_TYPE" \
      --source "$SOURCE"
  done
done

