#!/usr/bin/env bash
set -euo pipefail
CASTAR_KEY="${CASTAR_KEY:-xxxxxxxxxxxxxx}"
CASTAR_PATH="${CASTAR_PATH:-./app/CastarSDK}"
APP_CMD=( "$CASTAR_PATH" -key="$CASTAR_KEY" )
PROXY_FILE="${1:-proxies.txt}"
BASE_NS="${BASE_NS:-castarns}"
VETH_PREFIX="${VETH_PREFIX:-castar}"
WORKDIR="${WORKDIR:-/tmp/castar_clones}"
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
  setup_namespace "$ns" "$((120+i))"
  start_expressvpn_in_ns "$ns" "${REGIONS[$((i-1))]}"
  ip netns exec "$ns" bash -lc "cd '$(pwd)'; nohup ${APP_CMD[*]} >'$WORKDIR/app_${i}.log' 2>&1 &"
  echo "[$i] Castar started in $ns"
done
wait
