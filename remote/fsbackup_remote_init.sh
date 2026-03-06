#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup_remote_init.sh
#
# Run on SOURCE HOSTS (remote machines) as root.
#
# Creates/repairs:
#   - backup user for rsync/ssh pulls
#   - authorized_keys
#   - safe ACLs for protected paths (via --allow-path)
#   - node_exporter textfile_collector permissions WITHOUT breaking patchcheck
#
# Usage:
#   sudo ./fsbackup_remote_init.sh \
#     --backup-user backup \
#     --pubkey-file /path/to/id_ed25519_backup.pub \
#     --allow-path /etc/headscale \
#     --allow-path /etc/bind \
#     --allow-path /var/webmin \
#     --allow-path /etc/weewx \
#     --allow-path /var/www/html
#
# Notes:
# - --allow-path can be provided multiple times.
# - This script intentionally does NOT change /etc ACLs unless *required*,
#   and even then only on the target directories/files that fail access checks.
# =============================================================================

BACKUP_USER="backup"
BACKUP_HOME="/var/lib/fsbackup-src"
BACKUP_SHELL="/bin/bash"

PUBKEY_FILE=""
PUBKEY_TEXT=""

ALLOW_PATHS=()

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
PATCHCHECK_USER="patchcheck"

usage() {
  cat <<'EOF'
Usage:
  fsbackup_remote_init.sh --pubkey-file /path/to/key.pub [options]

Options:
  --backup-user USER        (default: backup)
  --backup-home DIR         (default: /var/lib/fsbackup-src)
  --pubkey-file FILE        SSH public key file to install for backup user
  --pubkey "ssh-ed25519 ..." Inline public key (useful for testing)
  --allow-path PATH         Grant backup read access to PATH (repeatable)
  --skip-textfile           Skip node_exporter textfile_collector perms
  -h|--help

Example:
  sudo ./fsbackup_remote_init.sh \
    --pubkey-file /var/lib/fsbackup/.ssh/id_ed25519_backup.pub \
    --allow-path /etc/headscale \
    --allow-path /etc/bind \
    --allow-path /var/webmin
EOF
}

SKIP_TEXTFILE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-user) BACKUP_USER="$2"; shift 2;;
    --backup-home) BACKUP_HOME="$2"; shift 2;;
    --pubkey-file) PUBKEY_FILE="$2"; shift 2;;
    --pubkey) PUBKEY_TEXT="$2"; shift 2;;
    --allow-path) ALLOW_PATHS+=("$2"); shift 2;;
    --skip-textfile) SKIP_TEXTFILE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

if [[ -n "$PUBKEY_FILE" ]]; then
  [[ -f "$PUBKEY_FILE" ]] || { echo "ERROR: pubkey file not found: $PUBKEY_FILE" >&2; exit 2; }
  PUBKEY_TEXT="$(cat "$PUBKEY_FILE")"
fi

if [[ -z "$PUBKEY_TEXT" ]]; then
  echo "ERROR: --pubkey-file or --pubkey is required" >&2
  exit 2
fi

command -v setfacl >/dev/null || { echo "ERROR: setfacl not installed"; exit 2; }
command -v getfacl >/dev/null || { echo "ERROR: getfacl not installed"; exit 2; }
command -v sshd >/dev/null 2>&1 || true

log() { echo "[$(date -Is)] $*"; }

ensure_user() {
  local u="$1" home="$2" shell="$3"

  if id "$u" >/dev/null 2>&1; then
    # Repair home/shell if wrong
    usermod -d "$home" "$u" >/dev/null 2>&1 || true
    usermod -s "$shell" "$u" >/dev/null 2>&1 || true
  else
    useradd -m -d "$home" -s "$shell" "$u"
  fi

  mkdir -p "$home"
  chown "$u":"$u" "$home" || true
  chmod 0755 "$home" || true
}

install_pubkey() {
  local u="$1" home
  home="$(getent passwd "$u" | cut -d: -f6)"

  mkdir -p "$home/.ssh"
  chown "$u":"$u" "$home/.ssh"
  chmod 0700 "$home/.ssh"

  local ak="$home/.ssh/authorized_keys"
  touch "$ak"
  chown "$u":"$u" "$ak"
  chmod 0600 "$ak"

  # Ensure key exists exactly once
  if ! grep -Fxq "$PUBKEY_TEXT" "$ak"; then
    echo "$PUBKEY_TEXT" >>"$ak"
  fi
}

# Safe ACL helper:
# - For each directory component, if backup can't traverse it, grant x.
# - For target dir: ensure rx
# - For target file: ensure r on file; ensure x on parents; r on file itself
ensure_backup_access_path() {
  local path="$1"

  # Normalize (strip trailing slash unless root)
  [[ "$path" != "/" ]] && path="${path%/}"

  if [[ ! -e "$path" ]]; then
    log "WARN allow-path missing: $path"
    return 0
  fi

  # Build list of parent dirs
  local cur="/" next=""
  IFS='/' read -r -a parts <<<"${path#/}"

  # Traverse parents
  for p in "${parts[@]}"; do
    next="${cur%/}/$p"
    # If next is the final and is a file, stop after ensuring parents
    if [[ -f "$path" && "$next" == "$path" ]]; then
      break
    fi

    # Only touch ACL if backup can't traverse
    if ! sudo -u "$BACKUP_USER" test -x "$next" 2>/dev/null; then
      # Grant traverse only (x) on restrictive dirs
      setfacl -m "u:${BACKUP_USER}:x" "$next" || true
    fi
    cur="$next"
  done

  if [[ -d "$path" ]]; then
    # Ensure backup can read+traverse the target dir
    if ! sudo -u "$BACKUP_USER" test -r "$path" 2>/dev/null || ! sudo -u "$BACKUP_USER" test -x "$path" 2>/dev/null; then
      setfacl -m "u:${BACKUP_USER}:rx" "$path" || true
    fi
  else
    # File: ensure parent dir traverse + file readable
    local parent
    parent="$(dirname "$path")"
    if ! sudo -u "$BACKUP_USER" test -x "$parent" 2>/dev/null; then
      setfacl -m "u:${BACKUP_USER}:x" "$parent" || true
    fi
    if ! sudo -u "$BACKUP_USER" test -r "$path" 2>/dev/null; then
      setfacl -m "u:${BACKUP_USER}:r" "$path" || true
    fi
  fi
}

choose_textfile_group() {
  # IMPORTANT: nodeexp_txt wins if present (your multi-writer design)
  if getent group nodeexp_txt >/dev/null; then
    echo "nodeexp_txt"
    return 0
  fi

  # fall back to node_exporter if you really want single-group model
  if getent group node_exporter >/dev/null; then
    echo "node_exporter"
    return 0
  fi

  # Create nodeexp_txt if nothing exists
  groupadd nodeexp_txt
  echo "nodeexp_txt"
}

fix_textfile_collector_perms() {
  [[ -d "$TEXTFILE_DIR" ]] || return 0

  local g
  g="$(choose_textfile_group)"

  # Ensure both writers are in the group
  id "$BACKUP_USER" >/dev/null 2>&1 && usermod -aG "$g" "$BACKUP_USER" || true
  id "$PATCHCHECK_USER" >/dev/null 2>&1 && usermod -aG "$g" "$PATCHCHECK_USER" || true

  # Enforce invariant:
  #   dir group == g AND setgid ON (so new files inherit group)
  chown root:"$g" "$TEXTFILE_DIR" || true
  chmod 2775 "$TEXTFILE_DIR" || true

  # Normalize existing prom files to the writer group and group-writable
  chgrp "$g" "$TEXTFILE_DIR"/*.prom 2>/dev/null || true
  chmod 0664 "$TEXTFILE_DIR"/*.prom 2>/dev/null || true

  # ACLs:
  # - allow group rwx on dir
  # - default ACL so new files keep correct perms
  setfacl -m "g:${g}:rwx" "$TEXTFILE_DIR" || true
  setfacl -d -m "g:${g}:rwx" "$TEXTFILE_DIR" || true
}

write_remote_metric() {
  # Best-effort metric for node_exporter textfile collector
  local prom="$TEXTFILE_DIR/fsbackup_remote_init.prom"
  local ts
  ts="$(date +%s)"

  mkdir -p "$TEXTFILE_DIR" 2>/dev/null || true

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# HELP fsbackup_remote_init_last_run_seconds Unix timestamp of last remote init run
# TYPE fsbackup_remote_init_last_run_seconds gauge
fsbackup_remote_init_last_run_seconds ${ts}

# HELP fsbackup_remote_init_status 0=ok 1=failed
# TYPE fsbackup_remote_init_status gauge
fsbackup_remote_init_status 0
EOF

  if [[ -d "$TEXTFILE_DIR" ]]; then
    chgrp "$(stat -c %G "$TEXTFILE_DIR")" "$tmp" 2>/dev/null || true
    chmod 0664 "$tmp" 2>/dev/null || true
  fi
  mv "$tmp" "$prom"
}

# --------------------------- MAIN ---------------------------------------------

log "Ensuring backup user: $BACKUP_USER"
ensure_user "$BACKUP_USER" "$BACKUP_HOME" "$BACKUP_SHELL"
install_pubkey "$BACKUP_USER"

log "Applying allow-path ACLs (${#ALLOW_PATHS[@]} items)"
for p in "${ALLOW_PATHS[@]}"; do
  ensure_backup_access_path "$p"
done

if [[ "$SKIP_TEXTFILE" -eq 0 ]]; then
  log "Fixing node_exporter textfile collector perms (patchcheck-safe)"
  fix_textfile_collector_perms
  write_remote_metric
else
  log "Skipping textfile collector perms (--skip-textfile)"
fi

# One-line verifier (requested):
# - backup must be able to rsync-list each allow-path (dry-run semantics)
# - and patchcheck must be able to write a prom file if the dir exists
VERIFY_OK=1

# Verify allow-paths read/traverse
for p in "${ALLOW_PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    if ! sudo -u "$BACKUP_USER" test -r "$p" 2>/dev/null && [[ -f "$p" ]]; then
      VERIFY_OK=0
    fi
    if ! sudo -u "$BACKUP_USER" test -x "$p" 2>/dev/null && [[ -d "$p" ]]; then
      VERIFY_OK=0
    fi
  fi
done

# Verify patchcheck writer path (if present)
if id "$PATCHCHECK_USER" >/dev/null 2>&1 && [[ -d "$TEXTFILE_DIR" ]]; then
  if ! sudo -u "$PATCHCHECK_USER" bash -c "echo ok > '$TEXTFILE_DIR/.patchcheck_write_test' && rm -f '$TEXTFILE_DIR/.patchcheck_write_test'" >/dev/null 2>&1; then
    VERIFY_OK=0
  fi
fi

if [[ "$VERIFY_OK" -eq 1 ]]; then
  echo "VERIFY: remote init OK"
else
  echo "VERIFY: remote init FAIL (check ACLs/groups)"
  exit 1
fi

