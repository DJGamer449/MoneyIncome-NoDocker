#!/usr/bin/env bash
set -euo pipefail
PROXY_FILE="${1:-proxies.txt}"
BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earn}"
WORKDIR="${WORKDIR:-/tmp/earnapp_clones}"
EARNAPP_BIN="${EARNAPP_BIN:-$(command -v earnapp 2>/dev/null || true)}"
mkdir -p "$WORKDIR"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_lib.sh"
[[ -n "$EARNAPP_BIN" ]] || { echo "earnapp binary not found"; exit 1; }
count=1
[[ -f "$PROXY_FILE" ]] && count=$(awk 'NF{c++} END{print c+0}' "$PROXY_FILE")
(( count > 0 )) || count=1
require_expressvpn_bins
ask_activation_if_needed
choose_regions "$count"
for ((i=1;i<=count;i++)); do
  ns="${BASE_NS}${i}"
  setup_namespace "$ns" "$((160+i))"
  start_expressvpn_in_ns "$ns" "${REGIONS[$((i-1))]}"
  ip netns exec "$ns" bash -lc "nohup '$EARNAPP_BIN' run >'$WORKDIR/app_${i}.log' 2>&1 &"
  echo "[$i] EarnApp started in $ns"
done
wait
