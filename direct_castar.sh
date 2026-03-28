#!/usr/bin/env bash
set -euo pipefail

INSTANCE_COUNT="${1:-1}"
BASE_NS="${BASE_NS:-castarns}"
VETH_PREFIX="${VETH_PREFIX:-castar}"
WORKDIR="${WORKDIR:-/tmp/castar_multi}"
SERVER="${SERVER:-smart}"
PROTOCOL="${PROTOCOL:-lightwayudp}"
CASTAR_KEY="${CASTAR_KEY:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app/expressvpn_runner_lib.sh"
CTL="$(xvpn_resolve_ctl)"
CASTAR_BIN="${SCRIPT_DIR}/app/CastarSDK"

mkdir -p "$WORKDIR"

start_instance() {
  local idx="$1"
  local ns inst_dir
  ns="$(xvpn_create_ns "$idx" "$BASE_NS" "$VETH_PREFIX")"
  inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"

  ip netns exec "$ns" bash -lc "cd '$SCRIPT_DIR'; export HOME='$inst_dir'; '$CASTAR_BIN' -key='${CASTAR_KEY}'" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  xvpn_cleanup_ns "$BASE_NS" "$VETH_PREFIX"
}

main() {
  xvpn_require_root
  [[ -n "$CASTAR_KEY" ]] || { echo "CASTAR_KEY is required"; exit 1; }
  [[ -x "$CASTAR_BIN" ]] || { echo "Castar binary not found at $CASTAR_BIN"; exit 1; }
  xvpn_setup_nat_once
  xvpn_activate_and_connect "$CTL" "$SERVER" "$PROTOCOL"

  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    start_instance "$i"
  done
  wait
}

trap cleanup EXIT
main "$@"
