#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_multi}"
WIPTER_EMAIL="${WIPTER_EMAIL:-}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-}"
mkdir -p "$WORKDIR"
require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; [[ -n "$WIPTER_EMAIL" && -n "$WIPTER_PASSWORD" ]] || { echo "Set WIPTER_EMAIL/WIPTER_PASSWORD"; exit 1; }; }
main(){
 require_root; install_expressvpn_files
 local code instances; ask_expressvpn_inputs code instances
 for ((i=1;i<=instances;i++)); do
   ns="${BASE_NS}${i}"; region="$(region_for_idx "$i")"
   setup_ns "$ns" "$i" "$VETH_PREFIX"
   start_expressvpn_in_ns "$ns" "$code" "$region" "$i" "$WORKDIR/expressvpn_${i}.log"
   ip netns exec "$ns" bash -lc "nohup ./app/antgain -email '$WIPTER_EMAIL' -password '$WIPTER_PASSWORD' >'$WORKDIR/app_${i}.log' 2>&1 &"
   echo "[$i] started Wipter in $ns region=$region"
 done
 wait
}
main "$@"
