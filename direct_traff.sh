#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"
APP_MODE="${APP_MODE:-traff}"
TRAFF_TOKEN="${TRAFF_TOKEN:-nblQB8tNIf6aj1Hs51/SJXqflMy0x1jPnsT6kVcYB8s=}"
PS_TOKEN="${PS_TOKEN:-}"
CASTAR_KEY="${CASTAR_KEY:-}"
BASE_NS="${BASE_NS:-traffns}"
VETH_PREFIX="${VETH_PREFIX:-traff}"
WORKDIR="${WORKDIR:-/tmp/traff_multi}"
mkdir -p "$WORKDIR"

require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; }
app_command() {
  case "$APP_MODE" in
    traff) echo "./app/cli start accept --token '$TRAFF_TOKEN'" ;;
    packetstream)
      [[ -n "$PS_TOKEN" ]] || { echo "PS_TOKEN is required for packetstream mode"; exit 1; }
      echo "env CID='$PS_TOKEN' PS_IS_DOCKER=true ./app/psclient" ;;
    castar)
      [[ -n "$CASTAR_KEY" ]] || { echo "CASTAR_KEY is required for castar mode"; exit 1; }
      echo "./app/CastarSDK -key='$CASTAR_KEY'" ;;
    *) echo "Unsupported APP_MODE=$APP_MODE"; exit 1 ;;
  esac
}
cleanup(){ pkill -f '/opt/expressvpn/start.sh' 2>/dev/null || true; }
trap cleanup INT TERM

main(){
  require_root
  install_expressvpn_files
  local code instances cmd
  ask_expressvpn_inputs code instances
  cmd="$(app_command)"
  for ((i=1;i<=instances;i++)); do
    ns="${BASE_NS}${i}"; region="$(region_for_idx "$i")"
    setup_ns "$ns" "$i" "$VETH_PREFIX"
    start_expressvpn_in_ns "$ns" "$code" "$region" "$i" "$WORKDIR/expressvpn_${i}.log"
    ip netns exec "$ns" bash -lc "nohup $cmd >'$WORKDIR/app_${i}.log' 2>&1 &"
    echo "[$i] started mode=$APP_MODE ns=$ns region=$region"
  done
  wait
}
main "$@"
