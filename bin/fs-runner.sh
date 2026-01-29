#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-runner.sh
#
# Executes filesystem snapshots after fs-doctor validation.
# Must be run as fsbackup user.
#
# Usage:
#   fs-runner.sh <snapshot-type> --class <class> [--dry-run] [--replace-existing]
#
# Example:
#   sudo -u fsbackup fs-runner.sh daily --class class2 --dry-run
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
SNAPSHOT_ROOT="/bak/snapshots"
TMP_ROOT="/bak/tmp/in-progress"
BACKUP_SSH_USER="backup"
LOG_FILE="/bak/logs/fsbackup.log"

SNAPSHOT_TYPE=""
CLASS=""
DRY_RUN=0
REPLACE=0

usage() {
  cat <<'EOF'
Usage:
  fs-runner.sh <snapshot-type> --class <class> [--dry-run] [--replace-existing]

Options:
  --class <name>         Target class from targets.yml
  --dry-run              Rsync dry-run only
  --replace-existing     Replace snapshot if it already exists
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

SNAPSHOT_TYPE="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
command -v yq >/dev/null || { echo "yq not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found"; exit 2; }
command -v rsync >/dev/null || { echo "rsync not found"; exit 2; }
command -v fs-doctor.sh >/dev/null || { echo "fs-doctor.sh not found in PATH"; exit 2; }

mkdir -p "$SNAPSHOT_ROOT" "$TMP_ROOT" "$(dirname "$LOG_FILE")"

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------
echo
echo "fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Dry-run:       $DRY_RUN"
echo "  Replace:       $REPLACE"
echo

# -----------------------------------------------------------------------------
# Preflight: fs-doctor gate (authoritative)
# -----------------------------------------------------------------------------
echo "Running fsbackup doctor gate..."
if ! fs-doctor.sh --class "$CLASS"; then
  echo
  echo "Preflight failed — fs-doctor reported failures. Aborting."
  exit 1
fi
echo "Preflight OK"
echo

# -----------------------------------------------------------------------------
# Load targets
# -----------------------------------------------------------------------------
mapfile -t TARGETS < <(yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE")
TOTAL="${#TARGETS[@]}"

SUCCESS=0
FAIL=0
FAILED_IDS=()

# -----------------------------------------------------------------------------
# Snapshot loop
# -----------------------------------------------------------------------------
for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"

  echo "→ Target: $id"
  echo "  Host:   $host"
  echo "  Source: $src"

  SNAPSHOT_DIR="${SNAPSHOT_ROOT}/${id}/${SNAPSHOT_TYPE}"
  TMP_DIR="${TMP_ROOT}/${id}"
  RSYNC_LOG="${TMP_DIR}/rsync.log"

  mkdir -p "$TMP_DIR"

  if [[ -d "$SNAPSHOT_DIR" && "$REPLACE" -eq 0 ]]; then
    echo "  Skipping (snapshot exists)"
    ((SUCCESS++))
    echo
    continue
  fi

  rm -rf "$SNAPSHOT_DIR"

  RSYNC_OPTS=(
    -a
    --delete
    --numeric-ids
    --relative
    --timeout=60
    --log-file="$RSYNC_LOG"
  )

  [[ "$DRY_RUN" -eq 1 ]] && RSYNC_OPTS+=(-n)

  if [[ "$host" == "fs" ]]; then
    # Local rsync
    if rsync "${RSYNC_OPTS[@]}" "${src%/}/" "$SNAPSHOT_DIR/"; then
      ((SUCCESS++))
    else
      echo "  ERROR: rsync failed (local)"
      ((FAIL++))
      FAILED_IDS+=("$id")
    fi
  else
    # Remote rsync
    if rsync "${RSYNC_OPTS[@]}" \
        "${BACKUP_SSH_USER}@${host}:${src%/}/" \
        "$SNAPSHOT_DIR/"; then
      ((SUCCESS++))
    else
      echo "  ERROR: rsync failed (remote)"
      ((FAIL++))
      FAILED_IDS+=("$id")
    fi
  fi

  echo
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "fs-runner summary"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Total targets: $TOTAL"
echo "  Succeeded:     $SUCCESS"
echo "  Failed:        $FAIL"
echo

if [[ "$FAIL" -gt 0 ]]; then
  echo "  Failed targets:"
  for f in "${FAILED_IDS[@]}"; do
    echo "    - $f"
  done
  echo
  exit 1
fi

exit 0

