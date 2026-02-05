#!/usr/bin/env bash
set -euo pipefail

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
OUT="${NODEEXP_DIR}/fsbackup_logrotate.prom"

CONF="/etc/logrotate.d/fsbackup"
STATE="/var/lib/logrotate/status"

ok=0
last_run_epoch=0

# Did logrotate run at all?
if [[ -f "$STATE" ]]; then
  last_run_epoch="$(stat -c %Y "$STATE")"
fi

# Try a dry-run validation
if logrotate -d "$CONF" >/dev/null 2>&1; then
  ok=1
fi

cat >"$OUT" <<EOF
# HELP fsbackup_logrotate_ok Whether fsbackup logrotate config validates cleanly (1=ok,0=error)
# TYPE fsbackup_logrotate_ok gauge
fsbackup_logrotate_ok ${ok}

# HELP fsbackup_logrotate_last_run_seconds Epoch timestamp of last logrotate status update
# TYPE fsbackup_logrotate_last_run_seconds gauge
fsbackup_logrotate_last_run_seconds ${last_run_epoch}
EOF

chgrp nodeexp_txt "$OUT"
chmod 0644 "$OUT"
