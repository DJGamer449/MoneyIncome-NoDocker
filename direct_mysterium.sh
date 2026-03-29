#!/usr/bin/env bash
set -euo pipefail
BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-myster}"
WORKDIR="${WORKDIR:-/tmp/mysterium_multi}"
MYST_BIN="${MYST_BIN:-myst}"
source "$(dirname "$0")/expressvpn_netns_lib.sh"

require_root_and_tools
command -v "$MYST_BIN" >/dev/null 2>&1 || { echo "myst not found; run ./install_mysterium_node.sh"; exit 1; }
prompt_vpn_inputs
setup_nat_once
mkdir -p "$WORKDIR"
trap 'cleanup_namespaces "$BASE_NS" "$WORKDIR"' INT TERM

for i in $(seq 1 "$INSTANCE_COUNT"); do
  ns="${BASE_NS}${i}"
  region="$(region_for_index "$((i-1))")"
  create_ns_with_veth "$ns" "$i" "$VETH_PREFIX"
  inst_dir="$WORKDIR/instance_$i"
  mkdir -p "$inst_dir"
  start_expressvpn_for_ns "$ns" "$i" "$region" "$WORKDIR" "$(pwd)"
  ip netns exec "$ns" bash -lc "
    export HOME='$inst_dir'
    export XDG_CONFIG_HOME='$inst_dir/.config'
    export XDG_DATA_HOME='$inst_dir/.local/share'
    export XDG_CACHE_HOME='$inst_dir/.cache'
    mkdir -p \"\$XDG_CONFIG_HOME\" \"\$XDG_DATA_HOME\" \"\$XDG_CACHE_HOME\"
    exec $MYST_BIN service --agreed-terms-and-conditions
  " >"$WORKDIR/app_${i}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${i}.pid"
done
wait
