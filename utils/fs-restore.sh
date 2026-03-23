#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-restore.sh — browse and restore from ZFS snapshots (v2.0)
#
# Snapshot data is accessed via the hidden .zfs/snapshot/ directory which
# ZFS exposes automatically on every dataset. No mount/unmount needed.
#
# Snapshot naming: <type>-<date>
#   daily:   daily-2026-03-23
#   weekly:  weekly-2026-W12
#   monthly: monthly-2026-03
#   annual:  annual-2026
#
# Usage:
#   fs-restore.sh list [--type <type>] [--class <class>] [--id <id>]
#   fs-restore.sh restore --class <class> --id <id> (--snapshot <name> | --latest [--type <type>]) --to <path>
#   fs-restore.sh restore --class <class> --id <id> (--snapshot <name> | --latest [--type <type>]) --to-host <host> --to-path <path>
#
# Examples:
#   fs-restore.sh list
#   fs-restore.sh list --class class2
#   fs-restore.sh list --class class2 --id nginx.data
#   fs-restore.sh list --type weekly
#   fs-restore.sh restore --class class2 --id nginx.data --latest --to /tmp/restore
#   fs-restore.sh restore --class class2 --id nginx.data --snapshot weekly-2026-W12 --to /tmp/restore
#   fs-restore.sh restore --class class1 --id ns1.bind.zones --latest --type daily --to-host ns1 --to-path /tmp/restore
# =============================================================================

. /etc/fsbackup/fsbackup.conf
PRIMARY_SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"
ZFS_BASE="${PRIMARY_SNAPSHOT_ROOT#/}"
BACKUP_SSH_USER="backup"

for cmd in zfs rsync; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found" >&2; exit 2; }
done

usage() {
  grep '^# ' "$0" | sed -n '/^# Usage:/,/^# Examples:/p' | sed 's/^# \?//'
  exit 0
}

CMD="${1:-}"
shift || true

TYPE=""
CLASS=""
ID=""
SNAPSHOT=""
LATEST=0
TO=""
TO_HOST=""
TO_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)      TYPE="$2"; shift 2 ;;
    --class)     CLASS="$2"; shift 2 ;;
    --id)        ID="$2"; shift 2 ;;
    --snapshot)  SNAPSHOT="$2"; shift 2 ;;
    --latest)    LATEST=1; shift ;;
    --to)        TO="$2"; shift 2 ;;
    --to-host)   TO_HOST="$2"; shift 2 ;;
    --to-path)   TO_PATH="$2"; shift 2 ;;
    -h|--help)   usage ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$TYPE" ]]; then
  case "$TYPE" in
    daily|weekly|monthly|annual) ;;
    *) echo "Invalid --type: $TYPE (must be daily|weekly|monthly|annual)" >&2; exit 2 ;;
  esac
fi

# list_snapshots <dataset> — print snapshot names (newest first), filtered by $TYPE if set
list_snapshots() {
  local dataset="$1"
  local prefix="${TYPE:+${TYPE}-}"
  zfs list -t snapshot -r -H -o name "$dataset" 2>/dev/null \
    | awk -F@ '{print $2}' \
    | grep "^${prefix}" \
    | sort -r
}

# resolve_snapshot <dataset> — echo the snapshot name to use for restore
resolve_snapshot() {
  local dataset="$1"
  if [[ -n "$SNAPSHOT" ]]; then
    echo "$SNAPSHOT"
    return
  fi
  if [[ "$LATEST" -eq 1 ]]; then
    local snap
    snap="$(list_snapshots "$dataset" | head -1)"
    if [[ -z "$snap" ]]; then
      echo "No snapshots found for ${dataset}${TYPE:+ (type=${TYPE})}" >&2
      exit 4
    fi
    echo "$snap"
    return
  fi
  echo "Provide --snapshot <name> or --latest" >&2
  exit 2
}

case "$CMD" in
# -----------------------------------------------------------------------------
  list)
    if [[ -z "$CLASS" && -z "$ID" ]]; then
      echo "Snapshots in ${ZFS_BASE}${TYPE:+ (type=${TYPE})}:"
      printf "  %-12s %-32s %s\n" "CLASS" "TARGET" "SNAPSHOTS"
      printf "  %-12s %-32s %s\n" "------------" "--------------------------------" "---------"
      declare -A counts
      while IFS= read -r line; do
        dataset="${line%%@*}"
        snapname="${line##*@}"
        rel="${dataset#${ZFS_BASE}/}"
        cls="${rel%%/*}"
        tgt="${rel#*/}"
        [[ "$cls" == "$tgt" || "$tgt" == */* ]] && continue
        key="${cls}|${tgt}"
        counts["$key"]=$(( ${counts["$key"]:-0} + 1 ))
      done < <(zfs list -t snapshot -r -H -o name "$ZFS_BASE" 2>/dev/null \
               | grep "@${TYPE:+${TYPE}-}" | sort)
      for key in $(echo "${!counts[@]}" | tr ' ' '\n' | sort); do
        cls="${key%%|*}"; tgt="${key#*|}"
        printf "  %-12s %-32s %d\n" "$cls" "$tgt" "${counts[$key]}"
      done

    elif [[ -n "$CLASS" && -z "$ID" ]]; then
      echo "Snapshots in ${ZFS_BASE}/${CLASS}${TYPE:+ (type=${TYPE})}:"
      printf "  %-32s %s\n" "TARGET" "SNAPSHOTS"
      printf "  %-32s %s\n" "--------------------------------" "---------"
      declare -A counts
      while IFS= read -r line; do
        dataset="${line%%@*}"
        rel="${dataset#${ZFS_BASE}/}"
        cls="${rel%%/*}"
        tgt="${rel#*/}"
        [[ "$cls" != "$CLASS" || "$tgt" == */* ]] && continue
        counts["$tgt"]=$(( ${counts["$tgt"]:-0} + 1 ))
      done < <(zfs list -t snapshot -r -H -o name "${ZFS_BASE}/${CLASS}" 2>/dev/null \
               | grep "@${TYPE:+${TYPE}-}" | sort)
      for tgt in $(echo "${!counts[@]}" | tr ' ' '\n' | sort); do
        printf "  %-32s %d\n" "$tgt" "${counts[$tgt]}"
      done

    else
      [[ -n "$CLASS" && -n "$ID" ]] || { echo "list: provide --class and --id for target-level listing" >&2; exit 2; }
      dataset="${ZFS_BASE}/${CLASS}/${ID}"
      echo "Snapshots for ${CLASS}/${ID}${TYPE:+ (type=${TYPE})}:"
      snaps="$(list_snapshots "$dataset")"
      if [[ -z "$snaps" ]]; then
        echo "  (none)"
      else
        while IFS= read -r s; do echo "  ${s}"; done <<<"$snaps"
      fi
    fi
    ;;

# -----------------------------------------------------------------------------
  restore)
    [[ -n "$CLASS" ]] || { echo "restore requires --class" >&2; exit 2; }
    [[ -n "$ID" ]]    || { echo "restore requires --id" >&2; exit 2; }
    [[ -n "$TO" || ( -n "$TO_HOST" && -n "$TO_PATH" ) ]] \
      || { echo "restore requires --to or (--to-host and --to-path)" >&2; exit 2; }

    dataset="${ZFS_BASE}/${CLASS}/${ID}"
    zfs list "$dataset" &>/dev/null || { echo "Dataset not found: $dataset" >&2; exit 4; }

    snap="$(resolve_snapshot "$dataset")"
    snap_data="${PRIMARY_SNAPSHOT_ROOT}/${CLASS}/${ID}/.zfs/snapshot/${snap}"

    if [[ ! -d "$snap_data" ]]; then
      echo "Snapshot data not found: $snap_data" >&2
      echo "Available snapshots:"
      list_snapshots "$dataset" | sed 's/^/  /'
      exit 4
    fi

    echo "Source:  ${CLASS}/${ID}@${snap}"
    echo "Data:    ${snap_data}"

    if [[ -n "$TO" ]]; then
      mkdir -p "$TO"
      rsync -a --info=progress2 "${snap_data}/" "${TO}/"
      echo "Restored to: ${TO}"
      exit 0
    fi

    ssh "${BACKUP_SSH_USER}@${TO_HOST}" "mkdir -p '${TO_PATH}'"
    rsync -a --info=progress2 "${snap_data}/" "${BACKUP_SSH_USER}@${TO_HOST}:${TO_PATH%/}/"
    echo "Restored to: ${TO_HOST}:${TO_PATH}"
    ;;

# -----------------------------------------------------------------------------
  -h|--help|"")
    usage
    ;;

  *)
    echo "Unknown command: ${CMD}" >&2
    usage
    ;;
esac
