#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-annual-promote.sh
# Promote December monthly snapshot → annual (class1 only)
# =============================================================================

. /etc/fsbackup/fsbackup.conf

SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"
LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/annual-promote.log"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
PROM_TMP="$(mktemp)"
PROM_OUT="${NODEEXP_DIR}/fsbackup_annual_promote.prom"

YEAR=""
DRY_RUN=0
NOW_EPOCH="$(date +%s)"

usage() {
  echo "Usage: fs-annual-promote.sh --year <YYYY> [--dry-run]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --year) YEAR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$YEAR" ]] || usage
mkdir -p "$LOG_DIR"

log() {
  echo "$(date -Is) [annual] $*" | tee -a "$LOG_FILE"
}

SRC="${SNAPSHOT_ROOT}/monthly/${YEAR}-12/class1"
DST="${SNAPSHOT_ROOT}/annual/${YEAR}/class1"

unlock_annual() {
  chmod -R u+w "${SNAPSHOT_ROOT}/annual" 2>/dev/null || true
}

lock_annual() {
  chmod -R u-w "${SNAPSHOT_ROOT}/annual" 2>/dev/null || true
}

log "Starting annual promote"
log "  Year:    ${YEAR}"
log "  Source:  ${SRC}"
log "  Dest:    ${DST}"
log "  Dry-run: ${DRY_RUN}"

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
if [[ ! -d "$SRC" ]]; then
  log "INFO December monthly snapshot not found, skipping"

  cat >"$PROM_TMP" <<EOF
fsbackup_annual_promote_success{year="${YEAR}"} 0
fsbackup_annual_promote_skipped{year="${YEAR}",reason="missing_source"} 1
fsbackup_annual_promote_last_run ${NOW_EPOCH}
EOF

  chgrp nodeexp_txt "$PROM_TMP"
  chmod 0644 "$PROM_TMP"
  mv "$PROM_TMP" "$PROM_OUT"
  exit 0
fi

if [[ -d "$DST" ]]; then
  log "INFO Annual snapshot already exists, skipping"

  cat >"$PROM_TMP" <<EOF
fsbackup_annual_promote_success{year="${YEAR}"} 1
fsbackup_annual_promote_skipped{year="${YEAR}",reason="already_exists"} 1
fsbackup_annual_promote_last_run ${NOW_EPOCH}
EOF

  chgrp nodeexp_txt "$PROM_TMP"
  chmod 0644 "$PROM_TMP"
  mv "$PROM_TMP" "$PROM_OUT"
  exit 0
fi

# -----------------------------------------------------------------------------
# Promotion
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$DST")"
unlock_annual

RSYNC_CMD=(rsync -a --numeric-ids)
[[ "$DRY_RUN" -eq 1 ]] && RSYNC_CMD+=(-n)

log "RUN rsync ${SRC} → ${DST}"
"${RSYNC_CMD[@]}" "${SRC%/}/" "$DST/"

lock_annual

BYTES="$(du -sb "$DST" 2>/dev/null | awk '{print $1}' || echo 0)"
log "OK annual snapshot created (${BYTES} bytes)"

# -----------------------------------------------------------------------------
# Metrics
# -----------------------------------------------------------------------------
cat >"$PROM_TMP" <<EOF
fsbackup_annual_promote_success{year="${YEAR}"} 1
fsbackup_annual_snapshot_bytes{year="${YEAR}"} ${BYTES}
fsbackup_annual_promote_last_run ${NOW_EPOCH}
EOF

chgrp nodeexp_txt "$PROM_TMP"
chmod 0644 "$PROM_TMP"
mv "$PROM_TMP" "$PROM_OUT"

log "Annual promote completed"
exit 0

