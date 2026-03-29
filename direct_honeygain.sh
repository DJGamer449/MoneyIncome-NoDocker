#!/usr/bin/env bash
set -euo pipefail
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
HONEYGAIN_DIR="${HONEYGAIN_DIR:-./app/honeygain_file}"
HONEYGAIN_BIN="${HONEYGAIN_BIN:-$HONEYGAIN_DIR/honeygain}"
source "$(dirname "$0")/expressvpn_netns_lib.sh"

require_root_and_tools
[[ -x "$HONEYGAIN_BIN" ]] || { echo "Missing $HONEYGAIN_BIN"; exit 1; }
EMAIL="${HONEYGAIN_EMAIL:-}"; PASS="${HONEYGAIN_PASSWORD:-}"
[[ -n "$EMAIL" ]] || read -rp "Honeygain email: " EMAIL
[[ -n "$PASS" ]] || read -rsp "Honeygain password: " PASS && echo
prompt_vpn_inputs
setup_nat_once
mkdir -p "$WORKDIR"
trap 'cleanup_namespaces "$BASE_NS" "$WORKDIR"' INT TERM

for i in $(seq 1 "$INSTANCE_COUNT"); do
  ns="${BASE_NS}${i}"
  region="$(region_for_index "$((i-1))")"
  create_ns_with_veth "$ns" "$i" "$VETH_PREFIX"
  start_expressvpn_for_ns "$ns" "$i" "$region" "$WORKDIR" "$(pwd)"
  ip netns exec "$ns" bash -lc "cd '$(pwd)'; export HOME='$WORKDIR/$ns/home'; export LD_LIBRARY_PATH='$HONEYGAIN_DIR':\${LD_LIBRARY_PATH:-}; exec '$HONEYGAIN_BIN' -tou-accept -email '$EMAIL' -pass '$PASS' -device 'honeygain-$i'" >"$WORKDIR/app_${i}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${i}.pid"
done
wait
