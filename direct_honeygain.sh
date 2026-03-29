#!/usr/bin/env bash
set -euo pipefail
PROXY_FILE="${1:-proxies.txt}"
BASE_NS="${BASE_NS:-hgne}"
VETH_PREFIX="${VETH_PREFIX:-hgv}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
HONEYGAIN_DIR="${HONEYGAIN_DIR:-./app/honeygain_file}"
HONEYGAIN_BIN="${HONEYGAIN_BIN:-$HONEYGAIN_DIR/honeygain}"
HONEYGAIN_ACCOUNTS_RAW="${HONEYGAIN_ACCOUNTS:-}"
mkdir -p "$WORKDIR"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_lib.sh"
[[ -x "$HONEYGAIN_BIN" ]] || { echo "Honeygain binary missing: $HONEYGAIN_BIN"; exit 1; }
mapfile -t ACCOUNTS < <(printf '%s\n' "$HONEYGAIN_ACCOUNTS_RAW" | awk 'NF')
count="${#ACCOUNTS[@]}"
(( count > 0 )) || { echo "No Honeygain accounts provided via HONEYGAIN_ACCOUNTS"; exit 1; }
require_expressvpn_bins
ask_activation_if_needed
choose_regions "$count"
for ((i=1;i<=count;i++)); do
  ns="${BASE_NS}${i}"
  setup_namespace "$ns" "$((200+i))"
  start_expressvpn_in_ns "$ns" "${REGIONS[$((i-1))]}"
  email="${ACCOUNTS[$((i-1))]%%|*}"
  pass="${ACCOUNTS[$((i-1))]#*|}"
  device="hg-${i}-$(hostname)"
  ip netns exec "$ns" bash -lc "cd '$(pwd)'; export LD_LIBRARY_PATH='$HONEYGAIN_DIR:\${LD_LIBRARY_PATH:-}'; nohup '$HONEYGAIN_BIN' -tou-accept -email '$email' -pass '$pass' -device '$device' >'$WORKDIR/app_${i}.log' 2>&1 &"
  echo "[$i] Honeygain started in $ns"
done
wait
