#!/usr/bin/env bash
set -euo pipefail
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_multi}"
WIPTER_DIR="${WIPTER_DIR:-./app/wipter}"
source "$(dirname "$0")/expressvpn_netns_lib.sh"

require_root_and_tools
[[ -d "$WIPTER_DIR" ]] || { echo "Missing $WIPTER_DIR"; exit 1; }
WIPTER_EMAIL="${WIPTER_EMAIL:-}"; WIPTER_PASSWORD="${WIPTER_PASSWORD:-}"
[[ -n "$WIPTER_EMAIL" ]] || read -rp "Enter Wipter email: " WIPTER_EMAIL
[[ -n "$WIPTER_PASSWORD" ]] || read -rsp "Enter Wipter password: " WIPTER_PASSWORD && echo
prompt_vpn_inputs
setup_nat_once
mkdir -p "$WORKDIR"
trap 'cleanup_namespaces "$BASE_NS" "$WORKDIR"' INT TERM

for i in $(seq 1 "$INSTANCE_COUNT"); do
  ns="${BASE_NS}${i}"
  region="$(region_for_index "$((i-1))")"
  create_ns_with_veth "$ns" "$i" "$VETH_PREFIX"
  start_expressvpn_for_ns "$ns" "$i" "$region" "$WORKDIR" "$(pwd)"
  ip netns exec "$ns" unshare -m bash -lc "
    mkdir -p /opt/wipter
    mount --bind '$WIPTER_DIR' /opt/wipter
    cd /opt/wipter
    export WIPTER_EMAIL='$WIPTER_EMAIL'
    export WIPTER_PASSWORD='$WIPTER_PASSWORD'
    exec bash ./wipter.sh
  " >"$WORKDIR/app_${i}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${i}.pid"
done
wait
