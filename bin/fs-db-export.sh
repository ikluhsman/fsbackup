#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-db-export.sh
#
# Usage:
#   fs-db-export.sh /etc/fsbackup/db/<app>.env
# =============================================================================

ENV_FILE="${1:-}"

if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
  echo "Usage: $0 /path/to/db.env" >&2
  exit 2
fi

# ------------------------------------------------------------------
# Load env
# ------------------------------------------------------------------
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ------------------------------------------------------------------
# Required vars
# ------------------------------------------------------------------
: "${DB_ENGINE:?missing DB_ENGINE}"
: "${DB_CONTAINER:?missing DB_CONTAINER}"
: "${DB_NAME:?missing DB_NAME}"
: "${DB_USER:?missing DB_USER}"
: "${DB_PASSWORD:?missing DB_PASSWORD}"
: "${EXPORT_ROOT:?missing EXPORT_ROOT}"
BACKUP_USER="${BACKUP_USER:-backup}"
RETENTION="${RETENTION:-14}"

HOST="$(hostname -s)"
TIMESTAMP="$(date +%F_%H-%M-%S)"
EPOCH_NOW="$(date +%s)"

EXPORT_DIR="${EXPORT_ROOT}"
EXPORT_FILE="${EXPORT_DIR}/${DB_NAME}_${TIMESTAMP}.sql.gz"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="${NODEEXP_DIR}/fsbackup_db_export_${DB_NAME}.prom"

mkdir -p "$EXPORT_DIR"

# ------------------------------------------------------------------
# Export (compressed)
# ------------------------------------------------------------------
STATUS=1
SIZE=0

echo "[$(date -Is)] Exporting ${DB_ENGINE} database '${DB_NAME}' from ${DB_CONTAINER}"

if [[ "$DB_ENGINE" == "mariadb" || "$DB_ENGINE" == "mysql" ]]; then
  docker exec \
    -e MYSQL_PWD="${DB_PASSWORD}" \
    "${DB_CONTAINER}" \
    mariadb-dump \
      -u "${DB_USER}" \
      --single-transaction \
      --quick \
      --routines \
      --events \
      --triggers \
      "${DB_NAME}" \
    | gzip -9 > "${EXPORT_FILE}"

elif [[ "$DB_ENGINE" == "postgres" ]]; then
  docker exec \
    -e PGPASSWORD="${DB_PASSWORD}" \
    "${DB_CONTAINER}" \
    pg_dump \
      -U "${DB_USER}" \
      "${DB_NAME}" \
    | gzip -9 > "${EXPORT_FILE}"

else
  echo "ERROR: unsupported DB_ENGINE=${DB_ENGINE}" >&2
  exit 2
fi

# ------------------------------------------------------------------
# Validate
# ------------------------------------------------------------------
if [[ -s "$EXPORT_FILE" ]]; then
  SIZE="$(stat -c %s "$EXPORT_FILE")"
  STATUS=0
  chown $BACKUP_USER:$BACKUP_USER "$EXPORT_FILE"
  echo "[$(date -Is)] Export complete (${SIZE} bytes, compressed)"
else
  echo "ERROR: export file missing or empty" >&2
fi

# ------------------------------------------------------------------
# Metrics (atomic write)
# ------------------------------------------------------------------
tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_db_export_success Last DB export success (1=ok,0=fail)
# TYPE fsbackup_db_export_success gauge
fsbackup_db_export_success{db="${DB_NAME}",engine="${DB_ENGINE}",host="${HOST}"} $((STATUS == 0))

# HELP fsbackup_db_export_last_timestamp Last DB export timestamp
# TYPE fsbackup_db_export_last_timestamp gauge
fsbackup_db_export_last_timestamp{db="${DB_NAME}",engine="${DB_ENGINE}",host="${HOST}"} ${EPOCH_NOW}

# HELP fsbackup_db_export_size_bytes Size of last compressed DB export
# TYPE fsbackup_db_export_size_bytes gauge
fsbackup_db_export_size_bytes{db="${DB_NAME}",engine="${DB_ENGINE}",host="${HOST}"} ${SIZE}
EOF

chmod 0644 "$tmp" 2>/dev/null || true
chown "$BACKUP_USER":nodeexp_txt "$tmp"
mv "$tmp" "$METRICS_FILE"

# ------------------------------------------------------------------
# Retention (keep newest N)
# ------------------------------------------------------------------
ls -1t "${EXPORT_DIR}"/*.sql.gz 2>/dev/null \
  | tail -n +$((RETENTION + 1)) \
  | xargs -r rm -f

exit "$STATUS"

