#!/usr/bin/env bash
set -euo pipefail

API_URL="https://prometheus.kluhsman.com/prometheus/api/v1/admin/tsdb/snapshot"
SNAPSHOT_BASE="/docker/volumes/prometheus_data/_data/prometheus_data/snapshots"
LINK_PATH="$SNAPSHOT_BASE/current_snapshot"

# Optional: if using self-signed certs, add -k to curl
CURL_OPTS="-sS --fail -XPOST"

echo "[prometheus-prebackup] Creating snapshot..."

RESPONSE=$(curl $CURL_OPTS "$API_URL")

SNAP_ID=$(echo "$RESPONSE" | jq -r '.data.name')

if [[ -z "$SNAP_ID" || "$SNAP_ID" == "null" ]]; then
    echo "[prometheus-prebackup] ERROR: Failed to extract snapshot ID"
    exit 1
fi

SNAP_PATH="$SNAPSHOT_BASE/$SNAP_ID"

echo "[prometheus-prebackup] Snapshot ID: $SNAP_ID"
echo "[prometheus-prebackup] Verifying snapshot directory exists..."

# Wait briefly in case of filesystem latency
for i in {1..5}; do
    if [[ -d "$SNAP_PATH" ]]; then
        break
    fi
    sleep 1
done

if [[ ! -d "$SNAP_PATH" ]]; then
    echo "[prometheus-prebackup] ERROR: Snapshot directory not found at $SNAP_PATH"
    exit 1
fi

echo "[prometheus-prebackup] Updating symlink..."

rm -f "$LINK_PATH"
ln -s "$SNAP_PATH" "$LINK_PATH"

echo "[prometheus-prebackup] Symlink created:"
ls -l "$LINK_PATH"

echo "[prometheus-prebackup] Done."

