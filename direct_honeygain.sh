#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
EXPRESSVPN_PROTOCOL="${EXPRESSVPN_PROTOCOL:-auto}"
EXPRESSVPN_ACTIVATION_CODE="${EXPRESSVPN_ACTIVATION_CODE:-}"
HONEYGAIN_DIR="${HONEYGAIN_DIR:-./app/honeygain_file}"
HONEYGAIN_BIN="${HONEYGAIN_BIN:-$HONEYGAIN_DIR/honeygain}"
HONEYGAIN_LIB_DIR="${HONEYGAIN_LIB_DIR:-$HONEYGAIN_DIR}"
HONEYGAIN_ACCOUNTS_RAW="${HONEYGAIN_ACCOUNTS:-}"

mkdir -p "$WORKDIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SCRIPT="${DIRECT_COMMON_PATH:-}"
if [[ -z "$COMMON_SCRIPT" || ! -f "$COMMON_SCRIPT" ]]; then
  for candidate in \
    "${BASE_DIR:-}/direct_expressvpn_common.sh" \
    "$SCRIPT_DIR/direct_expressvpn_common.sh" \
    "$(pwd)/direct_expressvpn_common.sh"
  do
    if [[ -f "$candidate" ]]; then
      COMMON_SCRIPT="$candidate"
      break
    fi
  done
fi
[[ -n "$COMMON_SCRIPT" && -f "$COMMON_SCRIPT" ]] || { echo "Cannot find direct_expressvpn_common.sh"; exit 1; }
source "$COMMON_SCRIPT"

main() {
  require_expressvpn_prereqs
  [[ -x "$HONEYGAIN_BIN" ]] || { echo "Honeygain binary not executable: $HONEYGAIN_BIN"; exit 1; }
  [[ -n "$HONEYGAIN_ACCOUNTS_RAW" ]] || { echo "HONEYGAIN_ACCOUNTS is required"; exit 1; }
  [[ -n "$EXPRESSVPN_ACTIVATION_CODE" ]] || { echo "EXPRESSVPN_ACTIVATION_CODE is required"; exit 1; }

  mapfile -t accounts < <(printf '%s\n' "$HONEYGAIN_ACCOUNTS_RAW" | sed '/^\s*$/d')
  (( ${#accounts[@]} > 0 )) || { echo "No Honeygain accounts provided."; exit 1; }

  cleanup_ns_prefix "$BASE_NS"

  for ((idx=1; idx<=INSTANCE_COUNT; idx++)); do
    ns="${BASE_NS}${idx}"
    inst_dir="$WORKDIR/instance_${idx}"
    mkdir -p "$inst_dir"
    create_netns_with_veth "$ns" "$idx" "$VETH_PREFIX"
    start_expressvpn_in_ns "$ns" "$idx" "$EXPRESSVPN_PROTOCOL" "$EXPRESSVPN_ACTIVATION_CODE" "$WORKDIR"

    account="${accounts[$(( (idx-1) % ${#accounts[@]} ))]}"
    email="${account%%|*}"
    password="${account#*|}"

    ip netns exec "$ns" bash -lc "cd '$(pwd)'; export HOME='$inst_dir'; export LD_LIBRARY_PATH='$HONEYGAIN_LIB_DIR:\${LD_LIBRARY_PATH:-}'; '$HONEYGAIN_BIN' -tou-accept -email '$email' -pass '$password' -device 'hg-${idx}'" >"$WORKDIR/app_${idx}.log" 2>&1 &
    echo $! >"$WORKDIR/app_${idx}.pid"
    echo "[$idx] Honeygain started for $email in $ns"
  done
  wait
}

trap 'for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done; cleanup_ns_prefix "$BASE_NS"' INT TERM
main
