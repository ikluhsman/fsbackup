#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-export-s3.sh
#
# Compresses + encrypts snapshots and uploads to S3.
# =============================================================================

BAK_ROOT="/bak"
SNAP_ROOT="${BAK_ROOT}/snapshots"
LOG_FILE="${BAK_ROOT}/logs/s3-export.log"

METRICS_DIR="/var/lib/node_exporter/textfile_collector"
AGE_PUBKEY_FILE="/etc/fs-backup/age.pub"

S3_BUCKET="s3://fs-backups"

# shellcheck source=/usr/local/lib/fs-exporter.sh
source /usr/local/lib/fs-exporter.sh

# -----------------------------
# Arguments
# -----------------------------
SNAPSHOT_TYPE=""
CLASS=""
TARGET_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot-type) SNAPSHOT_TYPE="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --target-id) TARGET_ID="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$SNAPSHOT_TYPE" ]] || exit 2
[[ -n "$CLASS" ]] || exit 2
[[ -n "$TARGET_ID" ]] || exit 2

START_TS="$(date +%s)"
END_TS=0
STATUS=1
ERROR_CODE=99
BYTES=0

METRICS_FILE="${METRICS_DIR}/fs_backup__${TARGET_ID}.prom"

log() {
  echo "$(date -Is) [$TARGET_ID] $*" >>"$LOG_FILE"
}

fail() {
  END_TS="$(date +%s)"
  emit_backup_metrics \
    --metrics-file "$METRICS_FILE" \
    --target-id "$TARGET_ID" \
    --class "$CLASS" \
    --host "fs" \
    --snapshot-type "$SNAPSHOT_TYPE" \
    --status 1 \
    --error-code "$1" \
    --start-ts "$START_TS" \
    --end-ts "$END_TS" \
    --duration "$((END_TS-START_TS))" \
    --bytes 0
  exit 1
}

# -----------------------------
# Locate snapshot
# -----------------------------
SNAP_DIR="${SNAP_ROOT}/${SNAPSHOT_TYPE}"
SNAP_NAME="$(ls -1 "$SNAP_DIR" | sort | tail -n 1)"
SRC="${SNAP_DIR}/${SNAP_NAME}/${CLASS}/${TARGET_ID}"

[[ -d "$SRC" ]] || fail 10

ARCHIVE="${TARGET_ID}--${SNAPSHOT_TYPE}--${SNAP_NAME}.tar.zst"
ENCRYPTED="${ARCHIVE}.age"

TMP="$(mktemp -d)"

log "Exporting snapshot $SRC"

# -----------------------------
# Archive + encrypt
# -----------------------------
tar -C "$SRC" -cf - . \
  | zstd -T0 -19 \
  | age -r "$(cat "$AGE_PUBKEY_FILE")" \
  >"${TMP}/${ENCRYPTED}"

BYTES="$(stat -c %s "${TMP}/${ENCRYPTED}")"

# -----------------------------
# Upload
# -----------------------------
aws s3 cp \
  "${TMP}/${ENCRYPTED}" \
  "${S3_BUCKET}/${CLASS}/${TARGET_ID}/${ENCRYPTED}" \
  || fail 60

rm -rf "$TMP"

END_TS="$(date +%s)"

emit_backup_metrics \
  --metrics-file "$METRICS_FILE" \
  --target-id "$TARGET_ID" \
  --class "$CLASS" \
  --host "fs" \
  --snapshot-type "$SNAPSHOT_TYPE" \
  --status 0 \
  --error-code 0 \
  --start-ts "$START_TS" \
  --end-ts "$END_TS" \
  --duration "$((END_TS-START_TS))" \
  --bytes "$BYTES" \
  --media s3 \
  --media-export-status 1 \
  --media-export-ts "$END_TS"

log "S3 export complete"
exit 0


