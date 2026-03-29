#!/usr/bin/env bash
set -euo pipefail
APP_CMD=( ./app/provider provide )
PROXY_FILE="${1:-proxies.txt}"
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-ur}"
WORKDIR="${WORKDIR:-/tmp/ur_clones}"
mkdir -p "$WORKDIR"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_lib.sh"
count=1
[[ -f "$PROXY_FILE" ]] && count=$(awk 'NF{c++} END{print c+0}' "$PROXY_FILE")
(( count > 0 )) || count=1
require_expressvpn_bins
ask_activation_if_needed
choose_regions "$count"
for ((i=1;i<=count;i++)); do
  ns="${BASE_NS}${i}"
  setup_namespace "$ns" "$((140+i))"
  start_expressvpn_in_ns "$ns" "${REGIONS[$((i-1))]}"
  ip netns exec "$ns" bash -lc "cd '$(pwd)'; nohup ${APP_CMD[*]} >'$WORKDIR/app_${i}.log' 2>&1 &"
  echo "[$i] UrNetwork started in $ns"
done
wait
