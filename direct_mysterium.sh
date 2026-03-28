#!/usr/bin/env bash
set -euo pipefail

INSTANCE_COUNT="${1:-1}"
BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-myster}"
WORKDIR="${WORKDIR:-/tmp/mysterium_multi}"
SERVER="${SERVER:-smart}"
PROTOCOL="${PROTOCOL:-lightwayudp}"
MYST_BIN="${MYST_BIN:-$(command -v myst 2>/dev/null || true)}"
MYST_BASE_DIR="${MYST_BASE_DIR:-$(pwd)/myst}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app/expressvpn_runner_lib.sh"
CTL="$(xvpn_resolve_ctl)"

mkdir -p "$WORKDIR" "$MYST_BASE_DIR"

start_instance() {
  local idx="$1"
  local ns root_dir
  ns="$(xvpn_create_ns "$idx" "$BASE_NS" "$VETH_PREFIX")"
  root_dir="$MYST_BASE_DIR/myst-$idx"
  mkdir -p "$root_dir/data" "$root_dir/logs"

  ip netns exec "$ns" bash -lc "
    export HOME='$root_dir'
    '$MYST_BIN' service --agreed-terms-and-conditions --data-dir='$root_dir/data' >'$root_dir/logs/myst.log' 2>&1
  " &
  echo $! >"$WORKDIR/myst_${idx}.pid"
}

cleanup() {
  for f in "$WORKDIR"/myst_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  xvpn_cleanup_ns "$BASE_NS" "$VETH_PREFIX"
}

main() {
  xvpn_require_root
  [[ -n "$MYST_BIN" ]] || { echo "myst binary not found"; exit 1; }
  xvpn_setup_nat_once
  xvpn_activate_and_connect "$CTL" "$SERVER" "$PROTOCOL"

  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    start_instance "$i"
  done
  wait
}

trap cleanup EXIT
main "$@"
