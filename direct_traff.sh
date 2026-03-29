#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"
APP_CMD=( ./app/cli start accept --token "${TRAFF_TOKEN:-nblQB8tNIf6aj1Hs51/SJXqflMy0x1jPnsT6kVcYB8s=}" )
BASE_NS="${BASE_NS:-traffns}"
VETH_PREFIX="${VETH_PREFIX:-traff}"
WORKDIR="${WORKDIR:-/tmp/traff_multi}"
mkdir -p "$WORKDIR"

require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; }
cleanup(){ pkill -f '/opt/expressvpn/start.sh' 2>/dev/null || true; }
trap cleanup INT TERM

main(){
  require_root
  install_expressvpn_files
  local code instances
  ask_expressvpn_inputs code instances
  for ((i=1;i<=instances;i++)); do
    ns="${BASE_NS}${i}"; region="$(region_for_idx "$i")"
    setup_ns "$ns" "$i" "$VETH_PREFIX"
    start_expressvpn_in_ns "$ns" "$code" "$region" "$i" "$WORKDIR/expressvpn_${i}.log"
    ip netns exec "$ns" bash -lc "nohup ${APP_CMD[*]} >'$WORKDIR/app_${i}.log' 2>&1 &"
    echo "[$i] started $ns with region=$region"
  done
  wait
}
main "$@"
