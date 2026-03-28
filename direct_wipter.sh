#!/usr/bin/env bash
set -euo pipefail

INSTANCE_COUNT="${1:-1}"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_multi}"
WIPTER_DIR="${WIPTER_DIR:-./app/wipter}"
SERVER="${SERVER:-smart}"
PROTOCOL="${PROTOCOL:-lightwayudp}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app/expressvpn_runner_lib.sh"
CTL="$(xvpn_resolve_ctl)"

mkdir -p "$WORKDIR"

start_instance() {
  local idx="$1"
  local ns root_dir log_file pid_file
  ns="$(xvpn_create_ns "$idx" "$BASE_NS" "$VETH_PREFIX")"
  root_dir="$WORKDIR/inst_${idx}"
  log_file="$WORKDIR/wipter_${idx}.log"
  pid_file="$WORKDIR/wipter_${idx}.pid"
  mkdir -p "$root_dir"

  ip netns exec "$ns" unshare -m bash -c "
    mount --make-rprivate / 2>/dev/null || true
    mkdir -p /opt/wipter
    mount --bind '$SCRIPT_DIR/$WIPTER_DIR' /opt/wipter
    export HOME='$root_dir'
    export WIPTER_EMAIL='${WIPTER_EMAIL:-}'
    export WIPTER_PASSWORD='${WIPTER_PASSWORD:-}'
    cd /opt/wipter
    nohup bash ./wipter.sh >'$log_file' 2>&1 &
    echo \$! > '$pid_file'
  "
}

cleanup() {
  for f in "$WORKDIR"/wipter_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  xvpn_cleanup_ns "$BASE_NS" "$VETH_PREFIX"
}

main() {
  xvpn_require_root
  [[ -d "$SCRIPT_DIR/$WIPTER_DIR" ]] || { echo "WIPTER_DIR not found: $SCRIPT_DIR/$WIPTER_DIR"; exit 1; }
  [[ -n "${WIPTER_EMAIL:-}" && -n "${WIPTER_PASSWORD:-}" ]] || { echo "WIPTER_EMAIL and WIPTER_PASSWORD are required"; exit 1; }
  xvpn_setup_nat_once
  xvpn_activate_and_connect "$CTL" "$SERVER" "$PROTOCOL"

  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    start_instance "$i"
  done
  wait
}

trap cleanup EXIT
main "$@"
