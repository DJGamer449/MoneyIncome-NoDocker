#!/usr/bin/env bash
set -euo pipefail
BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earn}"
WORKDIR="${WORKDIR:-/tmp/earnapp_multi}"
source "$(dirname "$0")/expressvpn_netns_lib.sh"

require_root_and_tools
command -v earnapp >/dev/null 2>&1 || { echo "earnapp not found"; exit 1; }
prompt_vpn_inputs
setup_nat_once
mkdir -p "$WORKDIR"
trap 'cleanup_namespaces "$BASE_NS" "$WORKDIR"' INT TERM

for i in $(seq 1 "$INSTANCE_COUNT"); do
  ns="${BASE_NS}${i}"
  region="$(region_for_index "$((i-1))")"
  create_ns_with_veth "$ns" "$i" "$VETH_PREFIX"
  inst_dir="$WORKDIR/instance_$i"
  mkdir -p "$inst_dir/etc_earnapp"
  uuidgen | tr '[:upper:]' '[:lower:]' > "$inst_dir/etc_earnapp/uuid"
  start_expressvpn_for_ns "$ns" "$i" "$region" "$WORKDIR" "$(pwd)"
  ip netns exec "$ns" unshare -m bash -lc "
    mkdir -p /etc/earnapp
    mount --bind '$inst_dir/etc_earnapp' /etc/earnapp
    /usr/bin/earnapp start || true
    exec /usr/bin/earnapp run
  " >"$WORKDIR/app_${i}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${i}.pid"
done
wait
