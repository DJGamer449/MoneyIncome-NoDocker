#!/usr/bin/env bash
set -euo pipefail
PROXY_FILE="${1:-proxies.txt}"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_clones}"
WIPTER_DIR="${WIPTER_DIR:-./app/wipter}"
WIPTER_SCRIPT="${WIPTER_SCRIPT:-$WIPTER_DIR/wipter.sh}"
WIPTER_BIN="${WIPTER_BIN:-$WIPTER_DIR/wipter-app}"
mkdir -p "$WORKDIR"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_lib.sh"
[[ -x "$WIPTER_SCRIPT" || -x "$WIPTER_BIN" ]] || { echo "Wipter executable not found"; exit 1; }
count=1
[[ -f "$PROXY_FILE" ]] && count=$(awk 'NF{c++} END{print c+0}' "$PROXY_FILE")
(( count > 0 )) || count=1
require_expressvpn_bins
ask_activation_if_needed
choose_regions "$count"
for ((i=1;i<=count;i++)); do
  ns="${BASE_NS}${i}"
  setup_namespace "$ns" "$((180+i))"
  start_expressvpn_in_ns "$ns" "${REGIONS[$((i-1))]}"
  if [[ -x "$WIPTER_SCRIPT" ]]; then
    ip netns exec "$ns" bash -lc "cd '$WIPTER_DIR'; nohup '$WIPTER_SCRIPT' >'$WORKDIR/app_${i}.log' 2>&1 &"
  else
    ip netns exec "$ns" bash -lc "cd '$WIPTER_DIR'; nohup '$WIPTER_BIN' >'$WORKDIR/app_${i}.log' 2>&1 &"
  fi
  echo "[$i] Wipter started in $ns"
done
wait
