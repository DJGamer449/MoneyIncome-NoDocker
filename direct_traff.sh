#!/usr/bin/env bash
set -euo pipefail

INSTANCE_COUNT="${1:-1}"
BASE_NS="${BASE_NS:-traffns}"
VETH_PREFIX="${VETH_PREFIX:-traff}"
WORKDIR="${WORKDIR:-/tmp/traff_multi}"
SERVER="${SERVER:-smart}"
PROTOCOL="${PROTOCOL:-lightwayudp}"
APP_CMD_STRING="${APP_CMD_STRING:-./app/cli start accept --token \"${TRAFF_TOKEN:-}\"}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app/expressvpn_runner_lib.sh"
CTL="$(xvpn_resolve_ctl)"

mkdir -p "$WORKDIR"

start_instance() {
  local idx="$1"
  local ns inst_dir
  ns="$(xvpn_create_ns "$idx" "$BASE_NS" "$VETH_PREFIX")"
  inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"

  ip netns exec "$ns" bash -lc "cd '$SCRIPT_DIR'; export HOME='$inst_dir'; ${APP_CMD_STRING}" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
  echo "[$idx] started in $ns via ExpressVPN($SERVER)"
}

cleanup() {
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  xvpn_cleanup_ns "$BASE_NS" "$VETH_PREFIX"
}

main() {
  xvpn_require_root
  xvpn_setup_nat_once
  [[ -n "${CTL:-}" ]] || { echo "expressvpnctl not found"; exit 1; }
  xvpn_activate_and_connect "$CTL" "$SERVER" "$PROTOCOL"

  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "INSTANCE_COUNT must be numeric"; exit 1; }
  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    start_instance "$i"
  done
  wait
}

trap cleanup EXIT
main "$@"
