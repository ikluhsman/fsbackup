#!/usr/bin/env bash
set -euo pipefail

TARGET_ID=""
CLASS=""
HOST=""
SOURCE=""
TYPE="dir"
SNAPSHOT_TYPE=""
DRY_RUN=0
REPLACE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-id) TARGET_ID="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    --type) TYPE="$2"; shift 2 ;;
    --snapshot-type) SNAPSHOT_TYPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE=1; shift ;;
    *) shift ;;
  esac
done

[[ -n "$TARGET_ID" && -n "$CLASS" && -n "$HOST" && -n "$SOURCE" && -n "$SNAPSHOT_TYPE" ]] || exit 2

DEST_BASE="/bak/snapshots/${CLASS}/${SNAPSHOT_TYPE}"
DEST="${DEST_BASE}/${TARGET_ID}"
TMP="/bak/tmp/in-progress/${TARGET_ID}"

mkdir -p "$TMP"

if [[ "$TYPE" == "file" ]]; then
  RSYNC_SRC="${HOST}:${SOURCE}"
else
  RSYNC_SRC="${HOST}:${SOURCE%/}/"
fi

RSYNC_OPTS=(-a --numeric-ids --delete)

[[ "$DRY_RUN" -eq 1 ]] && RSYNC_OPTS+=(-n)

mkdir -p "$DEST"

rsync "${RSYNC_OPTS[@]}" "$RSYNC_SRC" "$TMP/"

if [[ "$DRY_RUN" -eq 0 ]]; then
  rm -rf "$DEST"
  mv "$TMP" "$DEST"
else
  rm -rf "$TMP"
fi

