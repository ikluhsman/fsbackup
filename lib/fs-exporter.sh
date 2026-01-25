#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Prometheus metrics emitter for node_exporter textfile collector (shell-safe)
#
# Usage pattern (recommended):
#   METRICS_DIR="/var/lib/node_exporter/textfile_collector"
#   METRICS_FILE="${METRICS_DIR}/fs_backup.prom"
#   emit_backup_metrics \
#     --metrics-file "$METRICS_FILE" \
#     --target-id "files.technicom" \
#     --class "class1" \
#     --host "fs" \
#     --snapshot-type "daily" \
#     --status 0 \
#     --error-code 0 \
#     --start-ts 1737750000 \
#     --end-ts 1737750124 \
#     --duration 124 \
#     --bytes 1342177280 \
#     --file-count 18243 \
#     --snapshot-size-bytes 5368709120
#
# Notes:
# - Writes atomically (temp + mv) and uses file lock to avoid concurrency issues.
# - Emits numeric-only values to Prometheus (no high-cardinality strings).
# - Escapes label values to be Prometheus-safe.
# -----------------------------------------------------------------------------

# Escape label values for Prometheus exposition format.
# - Backslash -> \\
# - Double quote -> \"
# - Newline -> \n
_prom_escape_label_value() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Render labels in stable key order to avoid needless churn.
# Required labels: target_id, class, host, snapshot_type
_prom_labels() {
  local target_id="$1" class="$2" host="$3" snapshot_type="$4"
  printf 'target_id="%s",class="%s",host="%s",snapshot_type="%s"' \
    "$(_prom_escape_label_value "$target_id")" \
    "$(_prom_escape_label_value "$class")" \
    "$(_prom_escape_label_value "$host")" \
    "$(_prom_escape_label_value "$snapshot_type")"
}

# Helper: integer check (Prometheus likes plain numbers; float OK for throughput).
_is_number() {
  [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

# Emit backup metrics for ONE job/target into a shared .prom file.
# This implementation rewrites the file each time, with only the metrics for this target.
# If you want a single file for all targets, call this per target but pass a different
# metrics-file per target (recommended) OR implement append+dedupe logic.
emit_backup_metrics() {
  local metrics_file=""
  local target_id="" class="" host="" snapshot_type=""
  local status="" error_code=""
  local start_ts="" end_ts="" duration=""
  local bytes="" file_count="" snapshot_size_bytes=""
  local media="" media_export_status="" media_export_ts=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --metrics-file) metrics_file="$2"; shift 2 ;;
      --target-id) target_id="$2"; shift 2 ;;
      --class) class="$2"; shift 2 ;;
      --host) host="$2"; shift 2 ;;
      --snapshot-type) snapshot_type="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;                 # 0 success, 1 failed, 2 partial, 3 skipped
      --error-code) error_code="$2"; shift 2 ;;         # 0 no error; your enum
      --start-ts) start_ts="$2"; shift 2 ;;             # unix epoch seconds
      --end-ts) end_ts="$2"; shift 2 ;;                 # unix epoch seconds
      --duration) duration="$2"; shift 2 ;;             # seconds
      --bytes) bytes="$2"; shift 2 ;;                   # bytes transferred (rsync total transferred file size)
      --file-count) file_count="$2"; shift 2 ;;         # number of files in snapshot (optional)
      --snapshot-size-bytes) snapshot_size_bytes="$2"; shift 2 ;; # du -sb snapshot dir (optional)
      --media) media="$2"; shift 2 ;;                   # optional: local|s3|mdisc
      --media-export-status) media_export_status="$2"; shift 2 ;; # optional: 0/1
      --media-export-ts) media_export_ts="$2"; shift 2 ;;         # optional: epoch seconds
      *) echo "emit_backup_metrics: unknown arg: $1" >&2; return 2 ;;
    esac
  done

  # Required args validation
  [[ -n "$metrics_file" ]] || { echo "emit_backup_metrics: --metrics-file required" >&2; return 2; }
  [[ -n "$target_id" ]]    || { echo "emit_backup_metrics: --target-id required" >&2; return 2; }
  [[ -n "$class" ]]        || { echo "emit_backup_metrics: --class required" >&2; return 2; }
  [[ -n "$host" ]]         || { echo "emit_backup_metrics: --host required" >&2; return 2; }
  [[ -n "$snapshot_type" ]]|| { echo "emit_backup_metrics: --snapshot-type required" >&2; return 2; }
  [[ -n "$status" ]]       || { echo "emit_backup_metrics: --status required" >&2; return 2; }
  [[ -n "$error_code" ]]   || { echo "emit_backup_metrics: --error-code required" >&2; return 2; }
  [[ -n "$start_ts" ]]     || { echo "emit_backup_metrics: --start-ts required" >&2; return 2; }
  [[ -n "$end_ts" ]]       || { echo "emit_backup_metrics: --end-ts required" >&2; return 2; }
  [[ -n "$duration" ]]     || { echo "emit_backup_metrics: --duration required" >&2; return 2; }
  [[ -n "$bytes" ]]        || { echo "emit_backup_metrics: --bytes required" >&2; return 2; }

  # Numeric validation (lightweight)
  for v in "$status" "$error_code" "$start_ts" "$end_ts" "$duration" "$bytes"; do
    _is_number "$v" || { echo "emit_backup_metrics: non-numeric value: $v" >&2; return 2; }
  done
  if [[ -n "$file_count" ]]; then _is_number "$file_count" || { echo "emit_backup_metrics: non-numeric file_count" >&2; return 2; }; fi
  if [[ -n "$snapshot_size_bytes" ]]; then _is_number "$snapshot_size_bytes" || { echo "emit_backup_metrics: non-numeric snapshot_size_bytes" >&2; return 2; }; fi
  if [[ -n "$media_export_status" ]]; then _is_number "$media_export_status" || { echo "emit_backup_metrics: non-numeric media_export_status" >&2; return 2; }; fi
  if [[ -n "$media_export_ts" ]]; then _is_number "$media_export_ts" || { echo "emit_backup_metrics: non-numeric media_export_ts" >&2; return 2; }; fi

  # Throughput (MB/s) - safe, zero if duration==0
  local throughput_mb_s="0"
  if [[ "$duration" != "0" ]]; then
    # bytes / seconds / (1024*1024)
    throughput_mb_s="$(awk -v b="$bytes" -v d="$duration" 'BEGIN { if (d<=0) {print 0} else { printf "%.3f", (b/d)/1048576 } }')"
  fi

  local labels base_labels
  base_labels="$(_prom_labels "$target_id" "$class" "$host" "$snapshot_type")"

  # Ensure directory exists
  local metrics_dir
  metrics_dir="$(dirname "$metrics_file")"
  mkdir -p "$metrics_dir"

  # Lock + atomic write
  local lock_file="${metrics_file}.lock"
  local tmp_file
  tmp_file="$(mktemp "${metrics_file}.tmp.XXXXXX")"

  exec 9>"$lock_file"
  flock 9

  {
    # Core job-level metrics
    printf 'fs_backup_last_status{%s} %s\n' "$base_labels" "$status"
    printf 'fs_backup_last_error_code{%s} %s\n' "$base_labels" "$error_code"
    printf 'fs_backup_last_start_timestamp_seconds{%s} %s\n' "$base_labels" "$start_ts"
    printf 'fs_backup_last_end_timestamp_seconds{%s} %s\n' "$base_labels" "$end_ts"
    printf 'fs_backup_last_duration_seconds{%s} %s\n' "$base_labels" "$duration"
    printf 'fs_backup_last_bytes_transferred{%s} %s\n' "$base_labels" "$bytes"
    printf 'fs_backup_last_throughput_mb_per_second{%s} %s\n' "$base_labels" "$throughput_mb_s"

    # Snapshot integrity-ish metrics (optional but recommended)
    if [[ -n "$file_count" ]]; then
      printf 'fs_backup_snapshot_file_count{target_id="%s",snapshot_type="%s"} %s\n' \
        "$(_prom_escape_label_value "$target_id")" \
        "$(_prom_escape_label_value "$snapshot_type")" \
        "$file_count"
    fi
    if [[ -n "$snapshot_size_bytes" ]]; then
      printf 'fs_backup_snapshot_size_bytes{target_id="%s",snapshot_type="%s"} %s\n' \
        "$(_prom_escape_label_value "$target_id")" \
        "$(_prom_escape_label_value "$snapshot_type")" \
        "$snapshot_size_bytes"
    fi

    # Optional: media export status (e.g., after S3 export completes)
    if [[ -n "$media" && -n "$media_export_status" ]]; then
      printf 'fs_backup_media_export_status{target_id="%s",media="%s"} %s\n' \
        "$(_prom_escape_label_value "$target_id")" \
        "$(_prom_escape_label_value "$media")" \
        "$media_export_status"
    fi
    if [[ -n "$media" && -n "$media_export_ts" ]]; then
      printf 'fs_backup_media_export_timestamp_seconds{target_id="%s",media="%s"} %s\n' \
        "$(_prom_escape_label_value "$target_id")" \
        "$(_prom_escape_label_value "$media")" \
        "$media_export_ts"
    fi
  } >"$tmp_file"

  # Permissions: node_exporter usually reads as its own user; world-readable is typical.
  chmod 0644 "$tmp_file"

  # Atomic replace
  mv -f "$tmp_file" "$metrics_file"

  # Release lock
  flock -u 9
  exec 9>&-

  return 0
}

# -----------------------------------------------------------------------------
# Optional helper to map common failures to error codes.
# Use this in your scripts to keep error coding consistent.
# -----------------------------------------------------------------------------
fs_backup_error_code_from_context() {
  local ctx="${1:-}"
  case "$ctx" in
    ok) echo 0 ;;
    source_missing) echo 10 ;;
    dest_missing) echo 11 ;;
    dest_not_mounted) echo 12 ;;
    rsync_error) echo 20 ;;
    rsync_partial) echo 21 ;;
    lock_busy) echo 30 ;;
    permission) echo 40 ;;
    promote_failure) echo 50 ;;
    export_failure) echo 60 ;;
    *) echo 99 ;; # unknown
  esac
}

emit_promote_metrics() {
  local METRICS_FILE=""
  local FROM=""
  local TO=""
  local CLASS=""
  local STATUS=""
  local ERROR_CODE=""
  local START_TS=""
  local END_TS=""
  local DURATION=""
  local TARGETS=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --metrics-file) METRICS_FILE="$2"; shift 2 ;;
      --from) FROM="$2"; shift 2 ;;
      --to) TO="$2"; shift 2 ;;
      --class) CLASS="$2"; shift 2 ;;
      --status) STATUS="$2"; shift 2 ;;
      --error-code) ERROR_CODE="$2"; shift 2 ;;
      --start-ts) START_TS="$2"; shift 2 ;;
      --end-ts) END_TS="$2"; shift 2 ;;
      --duration) DURATION="$2"; shift 2 ;;
      --targets) TARGETS="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local TMP_FILE
  TMP_FILE="$(mktemp "${METRICS_FILE}.tmp.XXXXXX")"

  cat >"$TMP_FILE" <<EOF
# HELP fs_backup_promote_status Promotion job status (0=success,1=failure)
# TYPE fs_backup_promote_status gauge
fs_backup_promote_status{from="${FROM}",to="${TO}",class="${CLASS}"} ${STATUS}

# HELP fs_backup_promote_error_code Promotion error code
# TYPE fs_backup_promote_error_code gauge
fs_backup_promote_error_code{from="${FROM}",to="${TO}",class="${CLASS}"} ${ERROR_CODE}

# HELP fs_backup_promote_duration_seconds Promotion duration in seconds
# TYPE fs_backup_promote_duration_seconds gauge
fs_backup_promote_duration_seconds{from="${FROM}",to="${TO}",class="${CLASS}"} ${DURATION}

# HELP fs_backup_promote_targets Total targets promoted
# TYPE fs_backup_promote_targets gauge
fs_backup_promote_targets{from="${FROM}",to="${TO}",class="${CLASS}"} ${TARGETS}

# HELP fs_backup_promote_start_timestamp Promotion start timestamp (epoch)
# TYPE fs_backup_promote_start_timestamp gauge
fs_backup_promote_start_timestamp{from="${FROM}",to="${TO}",class="${CLASS}"} ${START_TS}

# HELP fs_backup_promote_end_timestamp Promotion end timestamp (epoch)
# TYPE fs_backup_promote_end_timestamp gauge
fs_backup_promote_end_timestamp{from="${FROM}",to="${TO}",class="${CLASS}"} ${END_TS}
EOF

  mv "$TMP_FILE" "$METRICS_FILE"
}

emit_prune_metrics() {
  local METRICS_FILE=""
  local TIER=""
  local STATUS=""
  local ERROR_CODE=""
  local START_TS=""
  local END_TS=""
  local DURATION=""
  local PRUNED=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --metrics-file) METRICS_FILE="$2"; shift 2 ;;
      --tier) TIER="$2"; shift 2 ;;
      --status) STATUS="$2"; shift 2 ;;
      --error-code) ERROR_CODE="$2"; shift 2 ;;
      --start-ts) START_TS="$2"; shift 2 ;;
      --end-ts) END_TS="$2"; shift 2 ;;
      --duration) DURATION="$2"; shift 2 ;;
      --pruned) PRUNED="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local TMP
  TMP="$(mktemp "${METRICS_FILE}.tmp.XXXXXX")"

  cat >"$TMP" <<EOF
# HELP fs_backup_prune_status Prune job status (0=success,1=failure)
# TYPE fs_backup_prune_status gauge
fs_backup_prune_status{tier="${TIER}"} ${STATUS}

# HELP fs_backup_prune_error_code Prune error code
# TYPE fs_backup_prune_error_code gauge
fs_backup_prune_error_code{tier="${TIER}"} ${ERROR_CODE}

# HELP fs_backup_prune_duration_seconds Prune duration in seconds
# TYPE fs_backup_prune_duration_seconds gauge
fs_backup_prune_duration_seconds{tier="${TIER}"} ${DURATION}

# HELP fs_backup_prune_pruned_total Total snapshots pruned
# TYPE fs_backup_prune_pruned_total counter
fs_backup_prune_pruned_total{tier="${TIER}"} ${PRUNED}

# HELP fs_backup_prune_start_timestamp Prune start timestamp
# TYPE fs_backup_prune_start_timestamp gauge
fs_backup_prune_start_timestamp{tier="${TIER}"} ${START_TS}

# HELP fs_backup_prune_end_timestamp Prune end timestamp
# TYPE fs_backup_prune_end_timestamp gauge
fs_backup_prune_end_timestamp{tier="${TIER}"} ${END_TS}
EOF

  mv "$TMP" "$METRICS_FILE"
}

