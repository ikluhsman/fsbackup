#!/usr/bin/env bash
# web/install.sh — one-time setup for the fsbackup web UI
# Run as root or with sudo.
set -u
set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}-->${NC} $*"; }
ok()      { echo -e "${GREEN}ok${NC}  $*"; }
warn()    { echo -e "${YELLOW}warn${NC} $*"; }
die()     { echo -e "${RED}err${NC}  $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Must run as root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    die "Please run as root: sudo $0"
fi

echo
echo "fsbackup web UI — setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# ---------------------------------------------------------------------------
# 1. Which user will run the web app?
# ---------------------------------------------------------------------------
read -rp "User that will run the web UI [fsbackup]: " WEB_USER
WEB_USER="${WEB_USER:-fsbackup}"

if ! id "$WEB_USER" &>/dev/null; then
    die "User '$WEB_USER' does not exist."
fi
info "Web UI will run as: $WEB_USER"
echo

# ---------------------------------------------------------------------------
# 2. Group membership (fsbackup group covers most paths)
# ---------------------------------------------------------------------------
if [[ "$WEB_USER" != "fsbackup" ]]; then
    if id -nG "$WEB_USER" | grep -qw fsbackup; then
        ok "$WEB_USER is already in the fsbackup group"
    else
        info "Adding $WEB_USER to the fsbackup group..."
        usermod -aG fsbackup "$WEB_USER"
        ok "Added — user must log out and back in (or run: newgrp fsbackup)"
    fi
    echo

    # -----------------------------------------------------------------------
    # 3. ACLs for paths not covered by the fsbackup group
    # -----------------------------------------------------------------------
    info "Applying ACLs for Prometheus textfile collector..."
    "$SCRIPT_DIR/../utils/fs-nodeexp-fix.sh" --web-user "$WEB_USER"
    ok "/var/lib/node_exporter/textfile_collector/"

    info "Applying ACLs for AWS credentials..."
    setfacl -m "u:${WEB_USER}:x"  /var/lib/fsbackup
    setfacl -m "u:${WEB_USER}:rx" /var/lib/fsbackup/.aws
    setfacl -m "u:${WEB_USER}:r"  /var/lib/fsbackup/.aws/credentials \
                                   /var/lib/fsbackup/.aws/config 2>/dev/null || \
        warn "AWS credentials not found — S3 page will not work until configured"
    ok "/var/lib/fsbackup/.aws/"
    echo
else
    ok "Running as fsbackup — no extra permissions needed"
    echo
fi

# ---------------------------------------------------------------------------
# 3b. systemd-journal group (needed to read journalctl logs in the UI)
# ---------------------------------------------------------------------------
if id -nG "$WEB_USER" | grep -qw systemd-journal; then
    ok "$WEB_USER is already in the systemd-journal group"
else
    info "Adding $WEB_USER to the systemd-journal group (needed for log viewer)..."
    usermod -aG systemd-journal "$WEB_USER"
    ok "Added — service must be restarted for the new group to take effect"
fi
echo


# ---------------------------------------------------------------------------
# 3d. ACL on /etc/fsbackup/ (needed to write targets.yml from the web UI)
# ---------------------------------------------------------------------------
info "Applying write ACL on /etc/fsbackup/ (needed for targets.yml editor)..."
setfacl -m "u:${WEB_USER}:rwx" /etc/fsbackup/
ok "/etc/fsbackup/ write ACL set for $WEB_USER"
echo

# ---------------------------------------------------------------------------
# 4. Write web/.env
# ---------------------------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    warn ".env already exists — skipping (delete it to regenerate)"
else
    info "Generating .env..."
    SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")

    read -rp "Enable authentication? [Y/n]: " AUTH_ANSWER
    AUTH_ANSWER="${AUTH_ANSWER:-Y}"
    AUTH_PASSWORD_HASH=""
    if [[ "${AUTH_ANSWER,,}" == "y" ]]; then
        AUTH_ENABLED=true
        while true; do
            read -rsp "Set UI password: " UI_PASSWORD; echo
            [[ -n "$UI_PASSWORD" ]] && break
            warn "Password cannot be empty"
        done
        AUTH_PASSWORD_HASH=$("$VENV/bin/python3" -c \
            "import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" \
            "$UI_PASSWORD")
        ok "Password hash generated"
    else
        AUTH_ENABLED=false
        warn "Auth disabled — anyone on the network can access the UI"
    fi

    read -rp "Bind host [0.0.0.0]: " BIND_HOST
    BIND_HOST="${BIND_HOST:-0.0.0.0}"
    read -rp "Bind port [8080]: " BIND_PORT
    BIND_PORT="${BIND_PORT:-8080}"

    cat > "$ENV_FILE" <<EOF
# fsbackup web UI configuration — generated by install.sh
HOST=$BIND_HOST
PORT=$BIND_PORT

AUTH_ENABLED=$AUTH_ENABLED
AUTH_PASSWORD_HASH=$AUTH_PASSWORD_HASH
SECRET_KEY=$SECRET

SNAPSHOT_ROOT=/backup/snapshots
MIRROR_ROOT=/backup2/snapshots
TARGETS_FILE=/etc/fsbackup/targets.yml

S3_BUCKET=fsbackup-snapshots-SUFFIX
S3_PROFILE=fsbackup
S3_REGION=us-west-2
EOF
    chown "${WEB_USER}:${WEB_USER}" "$ENV_FILE" 2>/dev/null || true
    chmod 600 "$ENV_FILE"
    ok "Written: $ENV_FILE"
fi
echo

# ---------------------------------------------------------------------------
# 5. Python venv + dependencies
# ---------------------------------------------------------------------------
VENV="$SCRIPT_DIR/.venv"

if [[ -d "$VENV" ]]; then
    ok "venv already exists at $VENV"
else
    info "Creating Python venv..."
    python3 -m venv "$VENV" || die "python3-venv not installed — run: apt install python3.12-venv"
    ok "venv created"
fi

info "Installing Python dependencies..."
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
ok "Dependencies installed"
echo

# ---------------------------------------------------------------------------
# 6. Supercronic scheduler (replaces systemd timers)
# ---------------------------------------------------------------------------
SUPERCRONIC_BIN="/usr/local/bin/supercronic"
SUPERCRONIC_VERSION="0.2.33"
SUPERCRONIC_URL="https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64"
SUPERCRONIC_SHA256="71b0d58cc53f76db3f6e0b71f4c6bc1a1a7c34fb15a6bb81fe2a5f3e571fab01"
CRONTAB_SRC="$SCRIPT_DIR/../conf/fsbackup.crontab"
CRONTAB_DST="/etc/fsbackup/fsbackup.crontab"
SCHEDULER_UNIT_SRC="$SCRIPT_DIR/../systemd/fsbackup-scheduler.service"
SCHEDULER_UNIT_DST="/etc/systemd/system/fsbackup-scheduler.service"

read -rp "Install supercronic scheduler? [y/N]: " INSTALL_SCHEDULER
INSTALL_SCHEDULER="${INSTALL_SCHEDULER:-N}"

if [[ "${INSTALL_SCHEDULER,,}" == "y" ]]; then
    # Install supercronic binary
    if [[ -f "$SUPERCRONIC_BIN" ]]; then
        ok "supercronic already installed at $SUPERCRONIC_BIN"
    else
        info "Downloading supercronic v${SUPERCRONIC_VERSION}..."
        curl -fsSL "$SUPERCRONIC_URL" -o "$SUPERCRONIC_BIN" || die "Failed to download supercronic"
        echo "$SUPERCRONIC_SHA256  $SUPERCRONIC_BIN" | sha256sum -c - || {
            rm -f "$SUPERCRONIC_BIN"
            die "supercronic checksum mismatch — binary removed"
        }
        chmod +x "$SUPERCRONIC_BIN"
        ok "supercronic installed at $SUPERCRONIC_BIN"
    fi

    # Deploy crontab
    info "Deploying crontab to $CRONTAB_DST..."
    cp "$CRONTAB_SRC" "$CRONTAB_DST"
    ok "Crontab deployed"

    # Install scheduler service
    info "Installing fsbackup-scheduler.service..."
    cp "$SCHEDULER_UNIT_SRC" "$SCHEDULER_UNIT_DST"
    systemctl daemon-reload

    read -rp "Disable legacy systemd timers and enable scheduler now? [y/N]: " MIGRATE_TIMERS
    MIGRATE_TIMERS="${MIGRATE_TIMERS:-N}"
    if [[ "${MIGRATE_TIMERS,,}" == "y" ]]; then
        info "Stopping and disabling fsbackup timers..."
        systemctl stop 'fsbackup-*.timer' 'fs-db-export@*.timer' 2>/dev/null || true
        systemctl disable 'fsbackup-*.timer' 'fs-db-export@*.timer' 2>/dev/null || true
        ok "Timers disabled"
        systemctl enable --now fsbackup-scheduler.service
        ok "fsbackup-scheduler.service enabled and started"
        systemctl status fsbackup-scheduler.service --no-pager -l | head -10
    else
        ok "Scheduler unit installed — enable with: systemctl enable --now fsbackup-scheduler.service"
        warn "Remember to disable legacy timers before enabling the scheduler to avoid double-runs"
    fi
fi
echo

# ---------------------------------------------------------------------------
# 7. Systemd unit (optional)
# ---------------------------------------------------------------------------
UNIT_SRC="$SCRIPT_DIR/../systemd/fsbackup-web.service"
UNIT_DST="/etc/systemd/system/fsbackup-web.service"

read -rp "Install systemd service? [y/N]: " INSTALL_UNIT
INSTALL_UNIT="${INSTALL_UNIT:-N}"

if [[ "${INSTALL_UNIT,,}" == "y" ]]; then
    if [[ ! -f "$UNIT_SRC" ]]; then
        warn "Unit file not found at $UNIT_SRC — writing a default one..."
        UNIT_SRC="$UNIT_DST"
    fi

    cat > "$UNIT_DST" <<EOF
[Unit]
Description=fsbackup web UI
After=network.target

[Service]
Type=simple
User=$WEB_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$VENV/bin/python3 $SCRIPT_DIR/main.py
EnvironmentFile=$ENV_FILE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    read -rp "Enable and start fsbackup-web.service now? [y/N]: " START_NOW
    if [[ "${START_NOW,,}" == "y" ]]; then
        systemctl enable --now fsbackup-web.service
        ok "Service enabled and started"
        systemctl status fsbackup-web.service --no-pager -l | head -20
    else
        ok "Unit installed — start with: systemctl enable --now fsbackup-web.service"
    fi
else
    echo
    info "To start manually:"
    echo "  cd $SCRIPT_DIR"
    echo "  sudo -u $WEB_USER $VENV/bin/python3 main.py"
fi

echo
echo -e "${GREEN}Setup complete.${NC}"
