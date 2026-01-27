sudo tee /usr/local/sbin/fsbackup-trust-host <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HOST="$1"
[[ -n "$HOST" ]] || { echo "Usage: fsbackup-trust-host <hostname>"; exit 1; }

ssh-keyscan -t ed25519 "$HOST" >> /var/lib/fsbackup/.ssh/known_hosts
chown fsbackup:fsbackup /var/lib/fsbackup/.ssh/known_hosts
chmod 644 /var/lib/fsbackup/.ssh/known_hosts

echo "Trusted host key for $HOST"
EOF

chmod 755 /usr/local/sbin/fsbackup-trust-host

