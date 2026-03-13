#!/usr/bin/env bash
# docker/entrypoint.sh — start supercronic + web UI
set -uo pipefail

CRONTAB="/etc/fsbackup/fsbackup.crontab"
VENV="/opt/fsbackup/web/.venv"

# ── Supercronic ───────────────────────────────────────────────────────────────
if [[ -f "$CRONTAB" ]]; then
    supercronic "$CRONTAB" &
    SUPERCRONIC_PID=$!
    echo "fsbackup: supercronic started (PID $SUPERCRONIC_PID)"
else
    echo "fsbackup: WARNING — $CRONTAB not found; scheduler not started"
    echo "fsbackup: Mount /etc/fsbackup and ensure fsbackup.crontab is present"
    SUPERCRONIC_PID=""
fi

# ── Graceful shutdown ─────────────────────────────────────────────────────────
_shutdown() {
    echo "fsbackup: shutting down..."
    [[ -n "$SUPERCRONIC_PID" ]] && kill "$SUPERCRONIC_PID" 2>/dev/null || true
    exit 0
}
trap _shutdown SIGTERM SIGINT

# ── Web UI ────────────────────────────────────────────────────────────────────
exec "$VENV/bin/python3" /opt/fsbackup/web/main.py
