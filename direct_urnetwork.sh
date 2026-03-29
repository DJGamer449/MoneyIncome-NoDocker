#!/usr/bin/env bash
set -euo pipefail

APP_CMD=( ./app/provider provide )
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-ur}"
WORKDIR="${WORKDIR:-/tmp/ur_multi}"
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
EXPRESSVPN_PROTOCOL="${EXPRESSVPN_PROTOCOL:-auto}"
EXPRESSVPN_ACTIVATION_CODE="${EXPRESSVPN_ACTIVATION_CODE:-}"

mkdir -p "$WORKDIR"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"

main() {
  require_expressvpn_prereqs
  [[ -n "$EXPRESSVPN_ACTIVATION_CODE" ]] || { echo "EXPRESSVPN_ACTIVATION_CODE is required"; exit 1; }
  cleanup_ns_prefix "$BASE_NS"

  for ((idx=1; idx<=INSTANCE_COUNT; idx++)); do
    ns="${BASE_NS}${idx}"
    inst_dir="$WORKDIR/instance_${idx}"
    mkdir -p "$inst_dir"
    create_netns_with_veth "$ns" "$idx" "$VETH_PREFIX"
    start_expressvpn_in_ns "$ns" "$idx" "$EXPRESSVPN_PROTOCOL" "$EXPRESSVPN_ACTIVATION_CODE" "$WORKDIR"
    ip netns exec "$ns" bash -lc "cd '$(pwd)'; export HOME='$inst_dir'; ${APP_CMD[*]}" >"$WORKDIR/app_${idx}.log" 2>&1 &
    echo $! >"$WORKDIR/app_${idx}.pid"
    echo "[$idx] UrNetwork started in $ns"
  done
  wait
}

trap 'for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done; cleanup_ns_prefix "$BASE_NS"' INT TERM
main
