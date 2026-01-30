#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-db-export.sh
# Usage:
#   fs-db-export.sh /etc/fsbackup/db/<app>.env
# =============================================================================

ENV_FILE="${1:-}"
[[ -f "$ENV_FILE" ]] || { echo "Missing env file"; exit 2; }

# shellcheck disable=SC1090
source "$ENV_FILE"

# Required
: "${DB_ENGINE:?}"
: "${DB_CONTAINER:?}"
: "${DB_NAME:?}"
: "${DB_USER:?}"
: "${DB_PASSWORD:?}"
: "${EXPORT_ROOT:?}"

APP="$(basename "$ENV_FILE" .env)"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="${METRICS_DIR}/fsbackup_db_export_${APP}.prom"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

DATE="$(date +%F_%H%M%S)"
OUT="${EXPORT_ROOT}/${APP}_${DATE}.sql.gz"
START_TS="$(date +%s)"

mkdir -p "$EXPORT_ROOT" "$METRICS_DIR"
umask 007

status=0
size=0

# -----------------------------------------------------------------------------
# Export
# -----------------------------------------------------------------------------
if [[ "$DB_ENGINE" == "postgres" ]]; then
  docker exec -e PGPASSWORD="$DB_PASSWORD" \
    "$DB_CONTAINER" \
    pg_dump \
      --dbname="$DB_NAME" \
      --username="$DB_USER" \
      --no-owner \
      --no-acl \
      --clean \
      --if-exists \
    | gzip -9 > "$OUT" || status=1

elif [[ "$DB_ENGINE" == "mysql" ]]; then
  docker exec \
    "$DB_CONTAINER" \
    mysqldump \
      -u"$DB_USER" \
      -p"$DB_PASSWORD" \
      --single-transaction \
      --quick \
      "$DB_NAME" \
    | gzip -9 > "$OUT" || status=1
else
  echo "Unsupported DB_ENGINE=$DB_ENGINE" >&2
  exit 3
fi

END_TS="$(date +%s)"
duration=$((END_TS - START_TS))

if [[ $status -eq 0 ]]; then
  size="$(stat -c '%s' "$OUT")"
  chown -R backup:backup "$OUT"
  chmod 640 "$OUT"
fi

# -----------------------------------------------------------------------------
# Retention
# -----------------------------------------------------------------------------
find "$EXPORT_ROOT" -type f -name '*.sql.gz' -mtime "+$RETENTION_DAYS" -delete
retained="$(ls -1 "$EXPORT_ROOT"/*.sql.gz 2>/dev/null | wc -l)"

# -----------------------------------------------------------------------------
# Prometheus metrics (atomic)
# -----------------------------------------------------------------------------
tmp="$(mktemp)"

cat >"$tmp" <<EOF
# HELP fsbackup_db_export_last_success Last DB export success (1=ok,0=fail)
# TYPE fsbackup_db_export_last_success gauge
fsbackup_db_export_last_success{app="${APP}",engine="${DB_ENGINE}"} $((status==0))

# HELP fsbackup_db_export_last_timestamp Last DB export timestamp (epoch)
# TYPE fsbackup_db_export_last_timestamp gauge
fsbackup_db_export_last_timestamp{app="${APP}",engine="${DB_ENGINE}"} ${END_TS}

# HELP fsbackup_db_export_last_size_bytes Size of last DB export
# TYPE fsbackup_db_export_last_size_bytes gauge
fsbackup_db_export_last_size_bytes{app="${APP}",engine="${DB_ENGINE}"} ${size}

# HELP fsbackup_db_export_duration_seconds Duration of DB export
# TYPE fsbackup_db_export_duration_seconds gauge
fsbackup_db_export_duration_seconds{app="${APP}",engine="${DB_ENGINE}"} ${duration}

# HELP fsbackup_db_export_retained_files Retained DB exports
# TYPE fsbackup_db_export_retained_files gauge
fsbackup_db_export_retained_files{app="${APP}"} ${retained}
EOF

chmod 0644 "$tmp"
mv "$tmp" "$METRICS_FILE"

exit "$status"

