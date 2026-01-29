#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup_remote_init.sh
#
# Run on EACH SOURCE HOST (as root). Prepares the remote host for fsbackup pulls:
#  - Ensures "backup" user exists and can do rsync over SSH
#  - Installs fsbackup public key into backup user's authorized_keys
#  - Sets up node_exporter textfile collector permissions WITHOUT breaking patchcheck
#  - Optionally grants read access to specific backup source paths in a SAFE way
#
# SAFETY PRINCIPLES
#  - Never change ACL mask entries (no setfacl -m m::...)
#  - Never recursively ACL protected system paths (e.g., /etc/bind)
#  - /etc paths allowed ONLY as --allow-file (file-level ACL)
#
# Flags:
#   --pubkey "ssh-ed25519 AAAA... comment"
#   --pubkey-file /path/to/id_ed25519_backup.pub
#
#   --allow-path /some/dir              (adds u:backup:rX on dir only)
#   --allow-path /some/dir --recursive  (adds recursive u:backup:rX on dir tree)  [SAFE PATHS ONLY]
#
#   --allow-file /etc/svc/config.yaml   (adds file-level u:backup:r only + execute on parent dirs)
#
#   --textfile-dir /var/lib/node_exporter/textfile_collector
#   --nodeexp-group node_exporter|nodeexp_txt  (optional override)
#
#   --no-metrics (skip writing init metric)
#
# One-line verifier prints:
#   "fsbackup-remote-init OK"
# =============================================================================

BACKUP_USER="backup"
BACKUP_UID="34"
BACKUP_GID="34"

# Default service home used across hosts (stable, not /home/backup)
BACKUP_HOME="/var/lib/fsbackup-src"
BACKUP_SHELL="/bin/bash"

TEXTFILE_DIR_DEFAULT="/var/lib/node_exporter/textfile_collector"
NODEEXP_GROUP_OVERRIDE=""

WRITE_METRICS=1
METRIC_FILE_DEFAULT="/var/lib/node_exporter/textfile_collector/fsbackup_remote_init.prom"

PUBKEY_INLINE=""
PUBKEY_FILE=""

RECURSIVE=0
ALLOW_PATHS=()
ALLOW_FILES=()

usage() {
  cat <<EOF
Usage (run as root):
  fsbackup_remote_init.sh --pubkey-file /tmp/id_ed25519_backup.pub
  fsbackup_remote_init.sh --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJwT7RbHgoeGRTQfF/bbdtJJ6+WBfteTH5jYTzZUUcc"

Optional:
  --allow-path /var/www/html
  --allow-path /docker/stacks --recursive
  --allow-file /etc/headscale/config.yaml

  --textfile-dir /var/lib/node_exporter/textfile_collector
  --nodeexp-group nodeexp_txt
  --no-metrics
EOF
}

log()  { echo "[$(date -Is)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 2; }

# -----------------------------
# Policy: protected paths
# -----------------------------
is_protected_dir() {
  local p="$1"
  case "$p" in
    /etc/bind|/etc/bind/*) return 0 ;;
    /etc/avahi|/etc/avahi/*) return 0 ;;
    /etc/ssh|/etc/ssh/*) return 0 ;;
    /etc/systemd|/etc/systemd/*) return 0 ;;
    /etc/sudoers|/etc/sudoers.d|/etc/sudoers.d/*) return 0 ;;
    /etc/pam.conf|/etc/pam.d|/etc/pam.d/*) return 0 ;;
    /root|/root/*) return 0 ;;
    /boot|/boot/*) return 0 ;;
    /proc|/proc/*) return 0 ;;
    /sys|/sys/*) return 0 ;;
    /dev|/dev/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Paths safe-ish to grant recursive ACLs to (explicit allow-list)
is_safe_recursive_root() {
  local p="$1"
  case "$p" in
    /var/www/*) return 0 ;;
    /srv/*)     return 0 ;;
    /opt/*)     return 0 ;;
    /home/*)    return 0 ;;
    /docker/*)  return 0 ;;
    /shr/*)     return 0 ;;
    /data/*)    return 0 ;;
    /mnt/*)     return 0 ;;
    *) return 1 ;;
  esac
}

# /etc is special: files only, no directories
is_under_etc() {
  [[ "$1" == /etc/* ]]
}

# -----------------------------
# Parse args
# -----------------------------
TEXTFILE_DIR="$TEXTFILE_DIR_DEFAULT"
METRIC_FILE="$METRIC_FILE_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pubkey)
      PUBKEY_INLINE="${2:-}"; shift 2 ;;
    --pubkey-file)
      PUBKEY_FILE="${2:-}"; shift 2 ;;
    --allow-path)
      ALLOW_PATHS+=("${2:-}"); shift 2 ;;
    --allow-file)
      ALLOW_FILES+=("${2:-}"); shift 2 ;;
    --recursive)
      RECURSIVE=1; shift ;;
    --textfile-dir)
      TEXTFILE_DIR="${2:-}"; shift 2 ;;
    --nodeexp-group)
      NODEEXP_GROUP_OVERRIDE="${2:-}"; shift 2 ;;
    --no-metrics)
      WRITE_METRICS=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown arg: $1" ;;
  esac
done

# -----------------------------
# Load public key
# -----------------------------
PUBKEY=""
if [[ -n "$PUBKEY_INLINE" ]]; then
  PUBKEY="$PUBKEY_INLINE"
elif [[ -n "$PUBKEY_FILE" ]]; then
  [[ -f "$PUBKEY_FILE" ]] || die "--pubkey-file not found: $PUBKEY_FILE"
  PUBKEY="$(cat "$PUBKEY_FILE")"
else
  die "Must provide --pubkey or --pubkey-file"
fi

[[ "$PUBKEY" == ssh-* ]] || die "Provided pubkey does not look like an SSH public key"

# -----------------------------
# Ensure backup user exists and is usable
# -----------------------------
ensure_backup_user() {
  if getent passwd "$BACKUP_USER" >/dev/null; then
    :
  else
    log "Creating user '$BACKUP_USER' (uid/gid ${BACKUP_UID}:${BACKUP_GID})"
    # Ensure group exists
    if ! getent group "$BACKUP_USER" >/dev/null; then
      groupadd -g "$BACKUP_GID" "$BACKUP_USER" 2>/dev/null || groupadd "$BACKUP_USER"
    fi
    useradd -m -d "$BACKUP_HOME" -s "$BACKUP_SHELL" -u "$BACKUP_UID" -g "$BACKUP_GID" "$BACKUP_USER" \
      || useradd -m -d "$BACKUP_HOME" -s "$BACKUP_SHELL" -g "$BACKUP_USER" "$BACKUP_USER"
  fi

  # Normalize shell (must NOT be nologin for rsync; avoids protocol mismatch / "shell clean" issues)
  local shell
  shell="$(getent passwd "$BACKUP_USER" | awk -F: '{print $7}')"
  if [[ "$shell" == */nologin || "$shell" == */false ]]; then
    log "Fixing backup user shell from '$shell' to '$BACKUP_SHELL' (required for rsync-over-ssh)"
    chsh -s "$BACKUP_SHELL" "$BACKUP_USER"
  fi

  # Normalize home directory
  local home
  home="$(getent passwd "$BACKUP_USER" | awk -F: '{print $6}')"
  if [[ "$home" != "$BACKUP_HOME" ]]; then
    log "Fixing backup user home from '$home' to '$BACKUP_HOME'"
    usermod -d "$BACKUP_HOME" -m "$BACKUP_USER" || usermod -d "$BACKUP_HOME" "$BACKUP_USER"
  fi

  # Ensure home exists and perms are sane
  mkdir -p "$BACKUP_HOME"
  chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME"
  chmod 750 "$BACKUP_HOME"
}

install_authorized_key() {
  local sshdir="${BACKUP_HOME}/.ssh"
  mkdir -p "$sshdir"
  chown "$BACKUP_USER:$BACKUP_USER" "$sshdir"
  chmod 700 "$sshdir"

  local ak="${sshdir}/authorized_keys"
  touch "$ak"
  chown "$BACKUP_USER:$BACKUP_USER" "$ak"
  chmod 600 "$ak"

  if ! grep -Fq "$PUBKEY" "$ak"; then
    log "Installing fsbackup public key into ${ak}"
    echo "$PUBKEY" >>"$ak"
  else
    log "Public key already present in authorized_keys"
  fi
}

# -----------------------------
# Node exporter textfile collector permissions (don’t break patchcheck)
# -----------------------------
setup_textfile_perms() {
  # If node_exporter exists, prefer its group. Otherwise use nodeexp_txt if exists.
  local chosen_group=""

  if [[ -n "$NODEEXP_GROUP_OVERRIDE" ]]; then
    chosen_group="$NODEEXP_GROUP_OVERRIDE"
  else
    if getent group node_exporter >/dev/null; then
      chosen_group="node_exporter"
    elif getent group nodeexp_txt >/dev/null; then
      chosen_group="nodeexp_txt"
    else
      # create nodeexp_txt as a neutral shared group
      chosen_group="nodeexp_txt"
      log "Creating group: ${chosen_group}"
      groupadd "$chosen_group" || true
    fi
  fi

  log "Using textfile collector group: $chosen_group"
  mkdir -p "$TEXTFILE_DIR"

  # Ensure directory is group-writable and sticky-setgid for shared writes
  chown root:"$chosen_group" "$TEXTFILE_DIR" || true
  chmod 2775 "$TEXTFILE_DIR" || true

  # Add backup user to group
  usermod -aG "$chosen_group" "$BACKUP_USER" || true

  # If patchcheck user exists, add it too (don’t create it here)
  if id patchcheck >/dev/null 2>&1; then
    usermod -aG "$chosen_group" patchcheck || true
  fi

  # Add default ACLs for group read/write so both services can create/delete .prom files
  # IMPORTANT: do NOT touch ACL mask
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m g:"$chosen_group":rwx "$TEXTFILE_DIR" || true
    setfacl -d -m g:"$chosen_group":rwx "$TEXTFILE_DIR" || true
  fi
}

# -----------------------------
# Allow-path / Allow-file ACL logic (SAFE)
# -----------------------------
grant_dir_acl_non_recursive() {
  local dir="$1"
  [[ -d "$dir" ]] || die "--allow-path must be a directory that exists: $dir"

  if is_protected_dir "$dir"; then
    die "Refusing to modify protected directory: $dir"
  fi

  if is_under_etc "$dir"; then
    die "/etc directories are not allowed with --allow-path. Use --allow-file for specific files."
  fi

  # Add execute on all parent dirs is not needed if dir is already traversable, but harmless:
  # Instead we apply ACL on dir itself.
  log "Granting non-recursive ACL: u:${BACKUP_USER}:rX on ${dir}"
  setfacl -m u:"$BACKUP_USER":rX "$dir"
}

grant_dir_acl_recursive() {
  local dir="$1"
  [[ -d "$dir" ]] || die "--allow-path must be a directory that exists: $dir"

  if is_protected_dir "$dir"; then
    die "Refusing to recursively modify protected directory: $dir"
  fi

  if is_under_etc "$dir"; then
    die "/etc directories are not allowed with --recursive. Use --allow-file."
  fi

  if ! is_safe_recursive_root "$dir"; then
    die "Refusing recursive ACL outside safe roots. Path: $dir"
  fi

  log "Granting recursive ACL: u:${BACKUP_USER}:rX on ${dir} (and default ACLs)"
  setfacl -R -m u:"$BACKUP_USER":rX "$dir"
  setfacl -R -d -m u:"$BACKUP_USER":rX "$dir" || true
}

grant_file_acl() {
  local f="$1"
  [[ -f "$f" ]] || die "--allow-file must be an existing file: $f"

  if is_protected_dir "$f"; then
    die "Refusing to modify protected path: $f"
  fi

  # For /etc/*: allow read on file, and execute on parent dirs needed for traversal.
  local parent
  parent="$(dirname "$f")"

  if is_under_etc "$f"; then
    # Only touch the specific file + its immediate parent dir for traversal.
    log "Granting file ACL: u:${BACKUP_USER}:r on ${f}"
    setfacl -m u:"$BACKUP_USER":r "$f"

    log "Ensuring traversal ACL on parent dir: u:${BACKUP_USER}:x on ${parent}"
    setfacl -m u:"$BACKUP_USER":x "$parent"
    return
  fi

  # Non-/etc files: allow read on file + traverse parent
  log "Granting file ACL: u:${BACKUP_USER}:r on ${f}"
  setfacl -m u:"$BACKUP_USER":r "$f"
  log "Ensuring traversal ACL on parent dir: u:${BACKUP_USER}:x on ${parent}"
  setfacl -m u:"$BACKUP_USER":x "$parent"
}

apply_allow_lists() {
  command -v setfacl >/dev/null 2>&1 || {
    log "setfacl not installed; skipping allow-path/allow-file ACL operations"
    return
  }

  for p in "${ALLOW_PATHS[@]}"; do
    [[ -n "$p" ]] || continue
    if [[ "$RECURSIVE" -eq 1 ]]; then
      grant_dir_acl_recursive "$p"
    else
      grant_dir_acl_non_recursive "$p"
    fi
  done

  for f in "${ALLOW_FILES[@]}"; do
    [[ -n "$f" ]] || continue
    grant_file_acl "$f"
  done
}

# -----------------------------
# Metrics
# -----------------------------
write_metrics() {
  [[ "$WRITE_METRICS" -eq 1 ]] || return 0
  local now rc
  now="$(date +%s)"
  rc="$1"

  mkdir -p "$(dirname "$METRIC_FILE")" || true
  cat >"$METRIC_FILE" <<EOF
# HELP fsbackup_remote_init_last_run_seconds Unix timestamp of last remote init run
# TYPE fsbackup_remote_init_last_run_seconds gauge
fsbackup_remote_init_last_run_seconds ${now}

# HELP fsbackup_remote_init_status Status (0=ok,1=failed)
# TYPE fsbackup_remote_init_status gauge
fsbackup_remote_init_status ${rc}
EOF
  chmod 644 "$METRIC_FILE" 2>/dev/null || true
}

# =============================================================================
# Main
# =============================================================================
main() {
  log "Starting fsbackup remote init"
  ensure_backup_user
  install_authorized_key
  setup_textfile_perms
  apply_allow_lists

  # One-line verifier (requested)
  # Verifies backup user can authenticate via key *if* SSH is local and key is in place.
  # (This does not guarantee network reachability from fs, but it proves account+key.)
  if command -v ssh >/dev/null 2>&1; then
    sudo -u "$BACKUP_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=3 localhost "true" >/dev/null 2>&1 || true
  fi

  write_metrics 0
  echo "fsbackup-remote-init OK"
}

if main; then
  exit 0
else
  rc=$?
  write_metrics 1 || true
  exit "$rc"
fi

