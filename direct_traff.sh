#!/usr/bin/env bash
set -euo pipefail
TRAFF_TOKEN="${TRAFF_TOKEN:-nblQB8tNIf6aj1Hs51/SJXqflMy0x1jPnsT6kVcYB8s=}"
APP_CMD=( ./app/cli start accept --token "$TRAFF_TOKEN" )
PROXY_FILE="${1:-proxies.txt}"
BASE_NS="${BASE_NS:-pxns}"
VETH_PREFIX="${VETH_PREFIX:-veth}"
WORKDIR="${WORKDIR:-/tmp/pxns_clones}"
mkdir -p "$WORKDIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASE_DIR:-$SCRIPT_DIR}/direct_expressvpn_lib.sh"

count=1
[[ -f "$PROXY_FILE" ]] && count=$(awk 'NF{c++} END{print c+0}' "$PROXY_FILE")
(( count > 0 )) || count=1
require_expressvpn_bins
ask_activation_if_needed
choose_regions "$count"

for ((i=1;i<=count;i++)); do
  ns="${BASE_NS}${i}"
  setup_namespace "$ns" "$((100+i))"
  start_expressvpn_in_ns "$ns" "${REGIONS[$((i-1))]}"
  log="$WORKDIR/app_${i}.log"
  ip netns exec "$ns" bash -lc "cd '$(pwd)'; nohup ${APP_CMD[*]} >'$log' 2>&1 &"
  echo "[$i] started in $ns region=${REGIONS[$((i-1))]}"
done
wait
