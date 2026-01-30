#!/usr/bin/env bash
set -u
. /etc/fsbackup/fsbackup.conf
BACKUP_SSH_USER="backup"

usage() {
  cat <<EOF
Usage:
  fs-restore.sh list --type <daily|weekly|monthly> [--class <class>] [--date <key>]
  fs-restore.sh restore --type <daily|weekly|monthly> --class <class> --id <id> [--date <key>|--latest] --to <path>
  fs-restore.sh restore --type <daily|weekly|monthly> --class <class> --id <id> [--date <key>|--latest] --to-host <host> --to-path <path>

Examples:
  fs-restore.sh list --type daily --class class2
  fs-restore.sh restore --type daily --class class2 --id nginx.config --latest --to /tmp/restore-nginx
  fs-restore.sh restore --type daily --class class2 --id bind.named.conf --date 2026-01-29 --to-host ns1 --to-path /tmp/restore-bind
EOF
}

CMD="${1:-}"
shift || true

TYPE=""
CLASS=""
ID=""
DATE=""
LATEST=0
TO=""
TO_HOST=""
TO_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --id) ID="$2"; shift 2 ;;
    --date) DATE="$2"; shift 2 ;;
    --latest) LATEST=1; shift ;;
    --to) TO="$2"; shift 2 ;;
    --to-host) TO_HOST="$2"; shift 2 ;;
    --to-path) TO_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$TYPE" == "daily" || "$TYPE" == "weekly" || "$TYPE" == "monthly" ]] || { echo "Missing/invalid --type" >&2; exit 2; }

pick_latest_key() {
  local base="${SNAPSHOT_ROOT}/${TYPE}"
  [[ -d "$base" ]] || return 1
  ls -1 "$base" | sort | tail -n 1
}

resolve_key() {
  if [[ -n "$DATE" ]]; then
    echo "$DATE"
  elif [[ "$LATEST" -eq 1 ]]; then
    pick_latest_key
  else
    echo "Missing --date or --latest" >&2
    exit 2
  fi
}

case "$CMD" in
  list)
    KEY="${DATE:-}"
    if [[ -z "$KEY" ]]; then
      echo "Available ${TYPE} keys:"
      ls -1 "${SNAPSHOT_ROOT}/${TYPE}" 2>/dev/null | sort || true
      exit 0
    fi
    if [[ -z "$CLASS" ]]; then
      echo "Classes under ${TYPE}/${KEY}:"
      ls -1 "${SNAPSHOT_ROOT}/${TYPE}/${KEY}" 2>/dev/null | sort || true
      exit 0
    fi
    echo "Targets under ${TYPE}/${KEY}/${CLASS}:"
    ls -1 "${SNAPSHOT_ROOT}/${TYPE}/${KEY}/${CLASS}" 2>/dev/null | sort || true
    ;;

  restore)
    [[ -n "$CLASS" && -n "$ID" ]] || { echo "restore requires --class and --id" >&2; exit 2; }
    KEY="$(resolve_key)"

    SRC="${SNAPSHOT_ROOT}/${TYPE}/${KEY}/${CLASS}/${ID}"
    [[ -d "$SRC" ]] || { echo "Snapshot not found: $SRC" >&2; exit 4; }

    if [[ -n "$TO" ]]; then
      mkdir -p "$TO"
      rsync -a "$SRC/" "$TO/"
      echo "Restored to: $TO"
      exit 0
    fi

    if [[ -n "$TO_HOST" && -n "$TO_PATH" ]]; then
      ssh "${BACKUP_SSH_USER}@${TO_HOST}" "mkdir -p '$TO_PATH'" >/dev/null
      rsync -a "$SRC/" "${BACKUP_SSH_USER}@${TO_HOST}:${TO_PATH%/}/"
      echo "Restored to: ${TO_HOST}:${TO_PATH}"
      exit 0
    fi

    echo "restore requires either --to or (--to-host and --to-path)" >&2
    exit 2
    ;;

  *)
    usage
    exit 2
    ;;
esac

