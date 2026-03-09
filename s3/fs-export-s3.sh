#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-export-s3.sh — upload snapshots to S3
#
# Uploads weekly, monthly, and annual tiers for all classes not in
# S3_SKIP_CLASSES. Idempotent: checks S3 before uploading and skips objects
# that are already present.
#
# S3 key structure:  <tier>/<class>/<target>/<target>--<date>.tar.zst.age
#
# Required in /etc/fsbackup/fsbackup.conf:
#   S3_BUCKET="fsbackup-snapshots-XXXXXX"
#
# Optional in /etc/fsbackup/fsbackup.conf:
#   S3_SKIP_CLASSES="class3"    (space-separated, defaults to class3)
#   S3_AWS_PROFILE="fsbackup"   (defaults to fsbackup)
# =============================================================================

. /etc/fsbackup/fsbackup.conf

S3_BUCKET="${S3_BUCKET:-}"
S3_SKIP_CLASSES="${S3_SKIP_CLASSES:-class3}"
AWS_PROFILE="${S3_AWS_PROFILE:-fsbackup}"
AGE_PUBKEY_FILE="/etc/fsbackup/age.pub"

LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/s3-export.log"
NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
PROM_OUT="${NODEEXP_DIR}/fsbackup_s3.prom"
PROM_TMP="$(mktemp)"

mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------

[[ -n "$S3_BUCKET" ]] || { echo "S3_BUCKET not set in fsbackup.conf" >&2; exit 2; }
[[ -f "$AGE_PUBKEY_FILE" ]] || { echo "age public key not found: $AGE_PUBKEY_FILE" >&2; exit 2; }

# Lock to prevent overlapping runs
exec 9>/run/lock/fsbackup-s3-export.lock
flock -n 9 || { echo "$(date +%Y-%m-%dT%H:%M:%S%z) [s3-export] already running, exiting" | tee -a "$LOG_FILE"; exit 0; }

log() {
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) [s3-export] $*" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

START_TS="$(date +%s)"
UPLOADED=0
SKIPPED=0
FAILED=0
BYTES_TOTAL=0

UPLOAD_TIERS=(weekly monthly annual)

log "Starting S3 export to s3://${S3_BUCKET}"
log "  Tiers:        ${UPLOAD_TIERS[*]}"
log "  Skip classes: ${S3_SKIP_CLASSES:-<none>}"

for tier in "${UPLOAD_TIERS[@]}"; do
  TIER_ROOT="${SNAPSHOT_ROOT}/${tier}"
  [[ -d "$TIER_ROOT" ]] || continue

  while IFS= read -r -d '' date_dir; do
    date_key="$(basename "$date_dir")"

    while IFS= read -r -d '' class_dir; do
      cls="$(basename "$class_dir")"

      if [[ -n "$S3_SKIP_CLASSES" && " $S3_SKIP_CLASSES " == *" $cls "* ]]; then
        log "SKIP class=${cls} tier=${tier} date=${date_key} (in S3_SKIP_CLASSES)"
        continue
      fi

      while IFS= read -r -d '' target_dir; do
        target="$(basename "$target_dir")"
        archive="${target}--${date_key}.tar.zst.age"
        s3_key="${tier}/${cls}/${target}/${archive}"
        s3_uri="s3://${S3_BUCKET}/${s3_key}"

        # Skip if already uploaded
        if aws s3api head-object \
            --bucket "$S3_BUCKET" \
            --key "$s3_key" \
            --profile "$AWS_PROFILE" \
            &>/dev/null; then
          log "EXISTS ${s3_uri}"
          SKIPPED=$((SKIPPED + 1))
          continue
        fi

        log "UPLOAD ${s3_uri}"

        if tar -C "$target_dir" -cf - . \
            | zstd -6 -T0 \
            | age -e -R "$AGE_PUBKEY_FILE" \
            | aws s3 cp - "$s3_uri" \
                --no-progress \
                --profile "$AWS_PROFILE"; then

          UPLOADED=$((UPLOADED + 1))

          BYTES=$(aws s3api head-object \
            --bucket "$S3_BUCKET" \
            --key "$s3_key" \
            --profile "$AWS_PROFILE" \
            --query 'ContentLength' \
            --output text 2>/dev/null || echo 0)
          BYTES_TOTAL=$((BYTES_TOTAL + BYTES))

          log "OK ${s3_uri} (${BYTES} bytes)"

          echo "fsbackup_s3_target_last_upload{tier=\"${tier}\",class=\"${cls}\",target=\"${target}\"} $(date +%s)" \
            >>"$PROM_TMP"

        else
          FAILED=$((FAILED + 1))
          log "ERROR upload failed: ${s3_uri}"

          echo "fsbackup_s3_target_last_failure{tier=\"${tier}\",class=\"${cls}\",target=\"${target}\"} $(date +%s)" \
            >>"$PROM_TMP"
        fi

      done < <(find "$class_dir" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    done < <(find "$date_dir" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  done < <(find "$TIER_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
done

END_TS="$(date +%s)"
DURATION=$((END_TS - START_TS))
EXIT_CODE=$([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)

cat >>"$PROM_TMP" <<EOF
# HELP fsbackup_s3_last_success Unix timestamp of last S3 export run completion
# TYPE fsbackup_s3_last_success gauge
fsbackup_s3_last_success $(date +%s)

# HELP fsbackup_s3_last_exit_code Exit code of last S3 export run (0=success)
# TYPE fsbackup_s3_last_exit_code gauge
fsbackup_s3_last_exit_code ${EXIT_CODE}

# HELP fsbackup_s3_uploaded_total Objects uploaded in this run
# TYPE fsbackup_s3_uploaded_total gauge
fsbackup_s3_uploaded_total ${UPLOADED}

# HELP fsbackup_s3_skipped_total Objects skipped (already present in S3) in this run
# TYPE fsbackup_s3_skipped_total gauge
fsbackup_s3_skipped_total ${SKIPPED}

# HELP fsbackup_s3_failed_total Objects that failed to upload in this run
# TYPE fsbackup_s3_failed_total gauge
fsbackup_s3_failed_total ${FAILED}

# HELP fsbackup_s3_bytes_total Bytes uploaded in this run
# TYPE fsbackup_s3_bytes_total gauge
fsbackup_s3_bytes_total ${BYTES_TOTAL}

# HELP fsbackup_s3_duration_seconds Duration of S3 export run in seconds
# TYPE fsbackup_s3_duration_seconds gauge
fsbackup_s3_duration_seconds ${DURATION}
EOF

chgrp nodeexp_txt "$PROM_TMP"
chmod 0640 "$PROM_TMP"
mv "$PROM_TMP" "$PROM_OUT"

log "S3 export complete: uploaded=${UPLOADED} skipped=${SKIPPED} failed=${FAILED} bytes=${BYTES_TOTAL} duration=${DURATION}s"
exit "$EXIT_CODE"
