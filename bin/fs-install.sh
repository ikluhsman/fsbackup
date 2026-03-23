#!/usr/bin/env bash
# fs-install.sh — fsbackup v2.0 bare-metal installer
# Run as root. Installs fsbackup to /opt/fsbackup, sets up user, ZFS
# permissions, systemd units, and optionally the web UI.
set -u
set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}-->${NC} $*"; }
ok()   { echo -e "${GREEN}ok${NC}  $*"; }
warn() { echo -e "${YELLOW}warn${NC} $*"; }
die()  { echo -e "${RED}err${NC}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="/opt/fsbackup"
CONF_DIR="/etc/fsbackup"
STATE_DIR="/var/lib/fsbackup"
LOG_DIR="${STATE_DIR}/log"
NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
FSBACKUP_USER="fsbackup"
FSBACKUP_UID=993

echo
echo "fsbackup v2.0 — bare-metal installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "This script will:"
echo "  1. Install required packages"
echo "  2. Create the fsbackup system user (UID ${FSBACKUP_UID})"
echo "  3. Install scripts to ${INSTALL_DIR}"
echo "  4. Create config skeleton in ${CONF_DIR}"
echo "  5. Set up ZFS delegation (zfs allow)"
echo "  6. Install and enable systemd units"
echo "  7. Apply schedule from fsbackup.conf"
echo "  8. Set up the web UI"
echo
read -rp "Continue? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }
echo

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
info "Installing required packages..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    rsync openssh-client jq zstd curl ca-certificates unzip \
    python3 python3-venv acl zfsutils-linux sanoid \
    || die "apt-get failed"
ok "Packages installed"

# AWS CLI v2 (not in Ubuntu 24.04 apt repos)
if ! command -v aws &>/dev/null; then
    info "Installing AWS CLI v2..."
    TMP_DIR="$(mktemp -d)"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${TMP_DIR}/awscliv2.zip"
    unzip -q "${TMP_DIR}/awscliv2.zip" -d "$TMP_DIR"
    "${TMP_DIR}/aws/install"
    rm -rf "$TMP_DIR"
    ok "AWS CLI v2 installed"
else
    ok "AWS CLI already installed: $(aws --version 2>&1)"
fi

# yq (go-based, not the python one)
if ! command -v yq &>/dev/null || ! yq --version 2>&1 | grep -q "mikefarah"; then
    info "Installing yq..."
    YQ_VERSION="4.50.1"
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
        -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
    ok "yq installed"
else
    ok "yq already installed"
fi
echo

# ---------------------------------------------------------------------------
# 2. fsbackup user
# ---------------------------------------------------------------------------
info "Setting up fsbackup user..."
if id "$FSBACKUP_USER" &>/dev/null; then
    ok "User '${FSBACKUP_USER}' already exists"
else
    groupadd -r --gid "$FSBACKUP_UID" "$FSBACKUP_USER"
    useradd -r --uid "$FSBACKUP_UID" -g "$FSBACKUP_USER" \
        -d "$STATE_DIR" -s /bin/bash "$FSBACKUP_USER"
    ok "User '${FSBACKUP_USER}' created (UID ${FSBACKUP_UID})"
fi

# Groups
for grp in systemd-journal nodeexp_txt docker; do
    if getent group "$grp" &>/dev/null; then
        usermod -aG "$grp" "$FSBACKUP_USER"
        ok "Added ${FSBACKUP_USER} to ${grp}"
    fi
done
echo

# ---------------------------------------------------------------------------
# 3. Install scripts
# ---------------------------------------------------------------------------
info "Installing to ${INSTALL_DIR}..."
rsync -a --delete \
    --exclude='.git' \
    --exclude='web/.venv' \
    --exclude='web/.env' \
    --exclude='conf/targets.yml' \
    "$REPO_DIR/" "$INSTALL_DIR/"
chown -R "${FSBACKUP_USER}:${FSBACKUP_USER}" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR"/bin/*.sh "$INSTALL_DIR"/utils/*.sh \
         "$INSTALL_DIR"/s3/*.sh 2>/dev/null || true
ok "Scripts installed"
echo

# ---------------------------------------------------------------------------
# 4. Config skeleton
# ---------------------------------------------------------------------------
info "Setting up ${CONF_DIR}..."
mkdir -p "$CONF_DIR" "$LOG_DIR" "$STATE_DIR/.ssh" "$STATE_DIR/.aws" "$NODEEXP_DIR"
chown -R "${FSBACKUP_USER}:${FSBACKUP_USER}" "$STATE_DIR"

if [[ ! -f "${CONF_DIR}/fsbackup.conf" ]]; then
    cp "$INSTALL_DIR/conf/fsbackup.conf.example" "${CONF_DIR}/fsbackup.conf"
    warn "Created ${CONF_DIR}/fsbackup.conf from example — edit before first run"
else
    ok "${CONF_DIR}/fsbackup.conf already exists"
fi

if [[ ! -f "${CONF_DIR}/targets.yml" ]]; then
    cp "$INSTALL_DIR/conf/targets.yml.example" "${CONF_DIR}/targets.yml" 2>/dev/null || \
        warn "No targets.yml.example found — create ${CONF_DIR}/targets.yml manually"
else
    ok "${CONF_DIR}/targets.yml already exists"
fi

# ACL: fsbackup user can write config dir (targets.yml editor in web UI)
setfacl -m "u:${FSBACKUP_USER}:rwx" "$CONF_DIR" 2>/dev/null || true

# Prometheus textfile dir
chgrp nodeexp_txt "$NODEEXP_DIR" 2>/dev/null || true
chmod 0775 "$NODEEXP_DIR" 2>/dev/null || true
setfacl -m "u:${FSBACKUP_USER}:rwx" "$NODEEXP_DIR" 2>/dev/null || true
ok "Config skeleton ready"
echo

# ---------------------------------------------------------------------------
# 5. ZFS delegation
# ---------------------------------------------------------------------------
info "Configuring ZFS delegation..."
SNAPSHOT_ROOT=""
[[ -f "${CONF_DIR}/fsbackup.conf" ]] && . "${CONF_DIR}/fsbackup.conf"
SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"
ZFS_DATASET="${SNAPSHOT_ROOT#/}"   # e.g. backup/snapshots

if zfs list "$ZFS_DATASET" &>/dev/null; then
    zfs allow "$FSBACKUP_USER" create,snapshot,mount,destroy "$ZFS_DATASET"
    chown -R "${FSBACKUP_USER}:${FSBACKUP_USER}" "${SNAPSHOT_ROOT}"
    ok "zfs allow + chown on ${ZFS_DATASET} for ${FSBACKUP_USER}"
else
    warn "ZFS dataset '${ZFS_DATASET}' not found — create the pool first, then run:"
    warn "  sudo zfs allow ${FSBACKUP_USER} create,snapshot,mount,destroy ${ZFS_DATASET}"
    warn "  sudo chown -R ${FSBACKUP_USER}:${FSBACKUP_USER} ${SNAPSHOT_ROOT}"
fi
echo

# ---------------------------------------------------------------------------
# 6. Systemd units
# ---------------------------------------------------------------------------
info "Installing systemd units..."
UNIT_SRC="$INSTALL_DIR/systemd"
UNIT_DST="/etc/systemd/system"

for f in "$UNIT_SRC"/*.service "$UNIT_SRC"/*.timer; do
    [[ -f "$f" ]] || continue
    cp "$f" "$UNIT_DST/"
done
ok "Units copied to ${UNIT_DST}"

systemctl daemon-reload

# Enable and start per-class runner timers (daily/weekly/monthly)
. "${CONF_DIR}/fsbackup.conf"
for class in class1 class2 class3; do
    for type in daily weekly monthly; do
        var="${class^^}_${type^^}_SCHEDULE"
        if [[ -n "${!var:-}" ]]; then
            unit="fsbackup-runner-${type}@${class}.timer"
            systemctl enable "$unit" 2>/dev/null && ok "Enabled: ${unit}"
        fi
    done
done

# Doctor timers (one per class)
for class in class1 class2 class3; do
    systemctl enable "fsbackup-doctor@${class}.timer" 2>/dev/null && \
        ok "Enabled: fsbackup-doctor@${class}.timer"
done

# Other timers
for unit in fsbackup-s3-export.timer fsbackup-scrub.timer fsbackup-logrotate-metric.timer; do
    systemctl enable "$unit" 2>/dev/null && ok "Enabled: ${unit}"
done
echo

# ---------------------------------------------------------------------------
# 7. Apply schedule
# ---------------------------------------------------------------------------
info "Applying schedule from fsbackup.conf..."
"$INSTALL_DIR/bin/fs-schedule-apply.sh"
echo

# ---------------------------------------------------------------------------
# 8. Web UI
# ---------------------------------------------------------------------------
read -rp "Set up the web UI now? [Y/n]: " SETUP_WEB
SETUP_WEB="${SETUP_WEB:-Y}"
if [[ "${SETUP_WEB,,}" == "y" ]]; then
    bash "$INSTALL_DIR/web/install.sh"
fi

echo
echo -e "${GREEN}Installation complete.${NC}"
echo
echo "Next steps:"
echo "  1. Edit ${CONF_DIR}/fsbackup.conf  — set SNAPSHOT_ROOT, schedules, S3 bucket"
echo "  2. Edit ${CONF_DIR}/targets.yml    — define your backup targets"
echo "  3. Run: sudo /opt/fsbackup/bin/fs-provision.sh  — create ZFS datasets"
echo "  4. Run: sudo /opt/fsbackup/utils/fs-trust-host.sh <host>  — for each remote host"
echo "  5. Run: systemctl start fsbackup-runner-daily@class1  — test a backup"
echo "  6. Run: systemctl start fsbackup-web  — start the web UI"
