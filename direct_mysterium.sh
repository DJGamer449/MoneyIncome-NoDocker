#!/usr/bin/env bash
set -euo pipefail
PROXY_FILE="${1:-proxies.txt}"
BASE_NS="${BASE_NS:-mystns}"
VETH_PREFIX="${VETH_PREFIX:-mystv}"
WORKDIR="${WORKDIR:-/tmp/mysterium_multi}"
MYST_BIN="${MYST_BIN:-$(command -v myst 2>/dev/null || true)}"
MYST_BASE_DIR="${MYST_BASE_DIR:-$(pwd)/myst}"
MYST_TERMS_FLAG="${MYST_TERMS_FLAG:---agreed-terms-and-conditions}"
mkdir -p "$WORKDIR" "$MYST_BASE_DIR"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_lib.sh"
[[ -n "$MYST_BIN" ]] || { echo "myst binary not found"; exit 1; }
count=1
[[ -f "$PROXY_FILE" ]] && count=$(awk 'NF{c++} END{print c+0}' "$PROXY_FILE")
(( count > 0 )) || count=1
require_expressvpn_bins
ask_activation_if_needed
choose_regions "$count"
for ((i=1;i<=count;i++)); do
  ns="${BASE_NS}${i}"
  data_dir="$MYST_BASE_DIR/$ns"
  mkdir -p "$data_dir"
  setup_namespace "$ns" "$((220+i))"
  start_expressvpn_in_ns "$ns" "${REGIONS[$((i-1))]}"
  ip netns exec "$ns" bash -lc "nohup '$MYST_BIN' --config-dir '$data_dir' $MYST_TERMS_FLAG >'$WORKDIR/app_${i}.log' 2>&1 &"
  echo "[$i] Mysterium started in $ns"
done
wait
