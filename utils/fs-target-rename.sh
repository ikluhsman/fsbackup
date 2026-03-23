#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-target-rename.sh
#
# Rename or delete a target's ZFS dataset (and all its snapshots).
#
# Usage:
#   fs-target-rename.sh \
#     --class class2 \
#     --from old.target.id \
#     --to new.target.id \
#     --move | --delete \
#     [--dry-run]
# =============================================================================

. /etc/fsbackup/fsbackup.conf

CLASS=""
FROM_ID=""
TO_ID=""
MODE=""
DRY_RUN=0

usage() {
  echo "Usage:"
  echo "  fs-target-rename.sh --class <class> --from <old-id> --to <new-id> (--move | --delete) [--dry-run]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)   CLASS="$2";   shift 2 ;;
    --from)    FROM_ID="$2"; shift 2 ;;
    --to)      TO_ID="$2";   shift 2 ;;
    --move)    MODE="move";  shift ;;
    --delete)  MODE="delete"; shift ;;
    --dry-run) DRY_RUN=1;   shift ;;
    *) usage ;;
  esac
done

[[ -n "$CLASS" && -n "$FROM_ID" && -n "$MODE" ]] || usage
[[ "$MODE" == "move" || "$MODE" == "delete" ]] || usage

if [[ "$MODE" == "move" && -z "$TO_ID" ]]; then
  echo "ERROR: --to is required with --move"
  exit 2
fi

log() {
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) [fs-target-rename] $*"
}

ZFS_BASE="${SNAPSHOT_ROOT#/}"
FROM_DATASET="${ZFS_BASE}/${CLASS}/${FROM_ID}"

# Verify source dataset exists
if ! zfs list -H -o name "$FROM_DATASET" &>/dev/null; then
  log "ERROR: dataset not found: ${FROM_DATASET}"
  exit 1
fi

SNAP_COUNT=$(zfs list -t snapshot -r -H -o name "$FROM_DATASET" 2>/dev/null | wc -l)

case "$MODE" in
  move)
    TO_DATASET="${ZFS_BASE}/${CLASS}/${TO_ID}"
    log "RENAME ${FROM_DATASET} → ${TO_DATASET}  (${SNAP_COUNT} snapshots)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      zfs rename "$FROM_DATASET" "$TO_DATASET"
      log "SUCCESS"
    fi
    ;;
  delete)
    log "DESTROY ${FROM_DATASET}  (${SNAP_COUNT} snapshots)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      zfs destroy -r "$FROM_DATASET"
      log "SUCCESS"
    fi
    ;;
esac

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: no changes made"
fi
