#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-mirror.sh — snapshot mirror with metrics
# =============================================================================

. /etc/fsbackup/fsbackup.conf

MODE="${1:-}"
case "$MODE" in
  daily|promote) ;;
  *)
    echo "Usage: fs-mirror.sh <daily|promote>"
    exit 2
    ;;
esac

# Backward-compatible no-op
if [[ -z "${SNAPSHOT_MIRROR_ROOT:-}" ]]; then
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) fs-mirror: SNAPSHOT_MIRROR_ROOT not set; skipping"
  exit 0
fi

SRC_ROOT="${SNAPSHOT_ROOT}"
DST_ROOT="${SNAPSHOT_MIRROR_ROOT}"

LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/mirror.log"
mkdir -p "$LOG_DIR"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
PROM_TMP="$(mktemp)"
PROM_OUT="${NODEEXP_DIR}/fsbackup_mirror_${MODE}.prom"

log() {
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) [mirror:${MODE}] $*" | tee -a "$LOG_FILE"
}

# Lock to avoid overlap
exec 9>/run/lock/fsbackup-mirror.lock
flock -n 9 || { log "WARN mirror already running, exiting"; exit 0; }

# Hard fail if mirror root unusable
[[ -d "$DST_ROOT" && -w "$DST_ROOT" ]] || {
  log "ERROR mirror root not writable: $DST_ROOT"
  exit 1
}

RSYNC_BASE=(rsync -a --ignore-existing)

mirror_dir() {
  local src="$1"
  local dst="$2"

  [[ -d "$src" ]] || {
    log "INFO source missing, skipping: $src"
    return 0
  }

  mkdir -p "$dst"

  log "START rsync: $src -> $dst"
  "${RSYNC_BASE[@]}" "${src%/}/" "${dst%/}/"
}

START_TS="$(date +%s)"
BYTES_TOTAL=0
rc=0
DATE_STR="$(date +%F)"

log "Beginning mirror run"
log "  SRC_ROOT: $SRC_ROOT"
log "  DST_ROOT: $DST_ROOT"

MIRROR_SKIP_CLASSES="${MIRROR_SKIP_CLASSES:-}"

case "$MODE" in
  daily)
    mapfile -t CLASSES < <(
      find "${SRC_ROOT}/daily/${DATE_STR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort || true
    )

    if [[ "${#CLASSES[@]}" -eq 0 ]]; then
      log "WARN no class directories found in ${SRC_ROOT}/daily/${DATE_STR}"
    fi

    for cls in "${CLASSES[@]}"; do
      if [[ -n "$MIRROR_SKIP_CLASSES" && " $MIRROR_SKIP_CLASSES " == *" $cls "* ]]; then
        log "SKIP class=${cls} (in MIRROR_SKIP_CLASSES)"
        continue
      fi

      SRC="${SRC_ROOT}/daily/${DATE_STR}/${cls}"
      DST="${DST_ROOT}/daily/${DATE_STR}/${cls}"

      if mirror_dir "$SRC" "$DST"; then
        [[ -d "$DST" ]] && BYTES_TOTAL=$((BYTES_TOTAL + $(du -sb "$DST" | awk '{print $1}')))
        log "OK rsync: $SRC -> $DST"
      else
        log "ERROR rsync failed: $SRC -> $DST"
        rc=1
      fi
    done
    ;;
  promote)
    for tier in weekly monthly; do
      SRC="${SRC_ROOT}/${tier}"
      DST="${DST_ROOT}/${tier}"

      if mirror_dir "$SRC" "$DST"; then
        [[ -d "$DST" ]] && BYTES_TOTAL=$((BYTES_TOTAL + $(du -sb "$DST" | awk '{print $1}')))
        log "OK rsync: $SRC -> $DST"
      else
        log "ERROR rsync failed: $SRC -> $DST"
        rc=1
      fi
    done
    ;;
esac

END_TS="$(date +%s)"
DURATION=$((END_TS - START_TS))
NOW_EPOCH="$(date +%s)"

cat >"$PROM_TMP" <<EOF
# HELP fsbackup_mirror_last_success Unix timestamp of last successful mirror run
# TYPE fsbackup_mirror_last_success gauge
fsbackup_mirror_last_success{mode="${MODE}"} ${NOW_EPOCH}

# HELP fsbackup_mirror_last_exit_code Exit code of last mirror run (0=success)
# TYPE fsbackup_mirror_last_exit_code gauge
fsbackup_mirror_last_exit_code{mode="${MODE}"} ${rc}

# HELP fsbackup_mirror_bytes_total Total bytes present in mirrored scope
# TYPE fsbackup_mirror_bytes_total gauge
fsbackup_mirror_bytes_total{mode="${MODE}"} ${BYTES_TOTAL}

# HELP fsbackup_mirror_duration_seconds Duration of mirror run
# TYPE fsbackup_mirror_duration_seconds gauge
fsbackup_mirror_duration_seconds{mode="${MODE}"} ${DURATION}
EOF

chgrp nodeexp_txt "$PROM_TMP"
chmod 0640 "$PROM_TMP"
mv "$PROM_TMP" "$PROM_OUT"

log "Mirror completed (rc=${rc}, duration=${DURATION}s, bytes=${BYTES_TOTAL})"
exit "$rc"

