#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"
BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-myster}"
WORKDIR="${WORKDIR:-/tmp/mysterium_multi}"
MYST_BASE_DIR="${MYST_BASE_DIR:-$(pwd)/myst}"
mkdir -p "$WORKDIR" "$MYST_BASE_DIR"
require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; command -v mysterium-node >/dev/null || { echo "mysterium-node missing"; exit 1; }; }
main(){
 require_root; install_expressvpn_files
 local code instances; ask_expressvpn_inputs code instances
 for ((i=1;i<=instances;i++)); do
   ns="${BASE_NS}${i}"; region="$(region_for_idx "$i")"; node_dir="$MYST_BASE_DIR/node_$i"
   mkdir -p "$node_dir"
   setup_ns "$ns" "$i" "$VETH_PREFIX"
   start_expressvpn_in_ns "$ns" "$code" "$region" "$i" "$WORKDIR/expressvpn_${i}.log"
   ip netns exec "$ns" bash -lc "nohup mysterium-node --datadir '$node_dir' service >'$WORKDIR/app_${i}.log' 2>&1 &"
   echo "[$i] started Mysterium in $ns region=$region"
 done
 wait
}
main "$@"
