#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/fsbackup/targets.yml"
TRUST_SCRIPT="/usr/local/sbin/fs-trust-host.sh"

CLASS="${1:?usage: fs-preflight.sh <class>}"

command -v yq >/dev/null
command -v jq >/dev/null
[[ -x "$TRUST_SCRIPT" ]] || { echo "Missing fs-trust-host.sh"; exit 2; }

echo
echo "fsbackup preflight check"
echo "Class: $CLASS"
echo

mapfile -t TARGETS < <(yq -o=json ".${CLASS}[]" "$CONFIG_FILE")

FAIL=0

for t in "${TARGETS[@]}"; do
  ID="$(jq -r .id <<<"$t")"
  HOST="$(jq -r .host <<<"$t")"
  SRC="$(jq -r .source <<<"$t")"

  echo "→ $ID ($HOST:$SRC)"

  # -----------------------------
  # Local host shortcut
  # -----------------------------
  if [[ "$HOST" == "fs" ]]; then
    if test -r "$SRC"; then
      echo "  ✔ local read ok"
    else
      echo "  ✖ local read failed"
      FAIL=1
    fi
    continue
  fi

  # -----------------------------
  # Trust host key
  # -----------------------------
  if ! "$TRUST_SCRIPT" "$HOST"; then
    echo "  ✖ host key trust failed"
    FAIL=1
    continue
  fi

  # -----------------------------
  # SSH connectivity
  # -----------------------------
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 backup@"$HOST" true 2>/dev/null; then
    echo "  ✖ ssh failed"
    FAIL=1
    continue
  fi

  # -----------------------------
  # Read permission test
  # -----------------------------
  if ! ssh backup@"$HOST" "test -r '$SRC'"; then
    echo "  ✖ read denied"
    FAIL=1
    continue
  fi

  echo "  ✔ ok"
done

echo
[[ "$FAIL" -eq 0 ]] && echo "Preflight: PASS" || echo "Preflight: FAIL"
exit "$FAIL"

