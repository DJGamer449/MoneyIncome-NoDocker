#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"
BASE_NS="${BASE_NS:-castarns}"
VETH_PREFIX="${VETH_PREFIX:-castar}"
WORKDIR="${WORKDIR:-/tmp/castar_multi}"
CASTAR_KEY="${CASTAR_KEY:-}"
mkdir -p "$WORKDIR"
require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; [[ -n "$CASTAR_KEY" ]] || { echo "Set CASTAR_KEY"; exit 1; }; }
main(){
 require_root; install_expressvpn_files
 local code instances; ask_expressvpn_inputs code instances
 for ((i=1;i<=instances;i++)); do
   ns="${BASE_NS}${i}"; region="$(region_for_idx "$i")"
   setup_ns "$ns" "$i" "$VETH_PREFIX"
   start_expressvpn_in_ns "$ns" "$code" "$region" "$i" "$WORKDIR/expressvpn_${i}.log"
   ip netns exec "$ns" bash -lc "nohup ./app/CastarSDK -key='$CASTAR_KEY' >'$WORKDIR/app_${i}.log' 2>&1 &"
   echo "[$i] started Castar in $ns region=$region"
 done
 wait
}
main "$@"
