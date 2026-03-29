#!/usr/bin/env bash
set -euo pipefail
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-ur}"
WORKDIR="${WORKDIR:-/tmp/ur_multi}"
source "$(dirname "$0")/expressvpn_netns_lib.sh"

require_root_and_tools
prompt_vpn_inputs
setup_nat_once
mkdir -p "$WORKDIR"
trap 'cleanup_namespaces "$BASE_NS" "$WORKDIR"' INT TERM

for i in $(seq 1 "$INSTANCE_COUNT"); do
  ns="${BASE_NS}${i}"
  region="$(region_for_index "$((i-1))")"
  create_ns_with_veth "$ns" "$i" "$VETH_PREFIX"
  start_expressvpn_for_ns "$ns" "$i" "$region" "$WORKDIR" "$(pwd)"
  ip netns exec "$ns" bash -lc "cd '$(pwd)'; export HOME='$WORKDIR/$ns/home'; ./app/provider provide" >"$WORKDIR/app_${i}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${i}.pid"
done
wait
