#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-myster}"
WORKDIR="${WORKDIR:-/tmp/mysterium_multi}"
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
EXPRESSVPN_PROTOCOL="${EXPRESSVPN_PROTOCOL:-auto}"
EXPRESSVPN_ACTIVATION_CODE="${EXPRESSVPN_ACTIVATION_CODE:-}"
MYST_BIN="${MYST_BIN:-$(command -v myst 2>/dev/null || true)}"
MYST_BASE_DIR="${MYST_BASE_DIR:-$(pwd)/myst}"
MYST_TERMS_FLAG="${MYST_TERMS_FLAG:---agreed-terms-and-conditions}"

mkdir -p "$WORKDIR" "$MYST_BASE_DIR"
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
  [[ -n "$MYST_BIN" && -x "$MYST_BIN" ]] || { echo "myst binary not found"; exit 1; }
  [[ -n "$EXPRESSVPN_ACTIVATION_CODE" ]] || { echo "EXPRESSVPN_ACTIVATION_CODE is required"; exit 1; }
  cleanup_ns_prefix "$BASE_NS"

  for ((idx=1; idx<=INSTANCE_COUNT; idx++)); do
    ns="${BASE_NS}${idx}"
    inst_dir="$MYST_BASE_DIR/instance_${idx}"
    mkdir -p "$inst_dir"
    create_netns_with_veth "$ns" "$idx" "$VETH_PREFIX"
    start_expressvpn_in_ns "$ns" "$idx" "$EXPRESSVPN_PROTOCOL" "$EXPRESSVPN_ACTIVATION_CODE" "$WORKDIR"

    ip netns exec "$ns" bash -lc "export HOME='$inst_dir'; '$MYST_BIN' service $MYST_TERMS_FLAG" >"$WORKDIR/app_${idx}.log" 2>&1 &
    echo $! >"$WORKDIR/app_${idx}.pid"
    echo "[$idx] Mysterium started in $ns"
  done
  wait
}

trap 'for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done; cleanup_ns_prefix "$BASE_NS"' INT TERM
main
