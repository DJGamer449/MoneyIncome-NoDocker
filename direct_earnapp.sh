#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"
BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earn}"
WORKDIR="${WORKDIR:-/tmp/earnapp_multi}"
mkdir -p "$WORKDIR"
require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; command -v earnapp >/dev/null || { echo "earnapp missing"; exit 1; }; }
main(){
 require_root; install_expressvpn_files
 local code instances; ask_expressvpn_inputs code instances
 for ((i=1;i<=instances;i++)); do
   ns="${BASE_NS}${i}"; region="$(region_for_idx "$i")"
   setup_ns "$ns" "$i" "$VETH_PREFIX"
   start_expressvpn_in_ns "$ns" "$code" "$region" "$i" "$WORKDIR/expressvpn_${i}.log"
   uuid="$(cat /proc/sys/kernel/random/uuid)"
   ip netns exec "$ns" bash -lc "nohup earnapp run \"$uuid\" >'$WORKDIR/app_${i}.log' 2>&1 &"
   echo "[$i] started EarnApp in $ns region=$region uuid=$uuid"
 done
 wait
}
main "$@"
