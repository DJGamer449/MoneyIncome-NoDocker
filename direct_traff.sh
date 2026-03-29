#!/usr/bin/env bash
set -euo pipefail

APP_MODE="${APP_MODE:-traff}"
case "$APP_MODE" in
  traff)
    APP_CMD=( ./app/cli start accept --token "${TRAFF_TOKEN_OVERRIDE:-}" )
    ;;
  packetstream)
    APP_CMD=( env CID="${PS_TOKEN_OVERRIDE:-}" PS_IS_DOCKER=true ./app/psclient )
    ;;
  castar)
    APP_CMD=( ./app/CastarSDK -key="${CASTAR_KEY_OVERRIDE:-}" )
    ;;
  *)
    echo "Unsupported APP_MODE: $APP_MODE (use traff|packetstream|castar)"
    exit 1
    ;;
esac
BASE_NS="${BASE_NS:-traffns}"
VETH_PREFIX="${VETH_PREFIX:-traff}"
WORKDIR="${WORKDIR:-/tmp/traff_expressvpn}"
mkdir -p "$WORKDIR"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/expressvpn_netns_common.sh"

cleanup() { cleanup_ns_batch "$BASE_NS" "$VETH_PREFIX" "$WORKDIR"; }
trap cleanup EXIT

main() {
  require_root_and_tools
  setup_nat_once

  case "$APP_MODE" in
    traff)
      [[ -n "${TRAFF_TOKEN_OVERRIDE:-}" ]] || { echo "TRAFF_TOKEN_OVERRIDE is required"; exit 1; }
      ;;
    packetstream)
      [[ -n "${PS_TOKEN_OVERRIDE:-}" ]] || { echo "PS_TOKEN_OVERRIDE is required"; exit 1; }
      ;;
    castar)
      [[ -n "${CASTAR_KEY_OVERRIDE:-}" ]] || { echo "CASTAR_KEY_OVERRIDE is required"; exit 1; }
      ;;
  esac

  read -rsp "Enter ExpressVPN activation key: " ACTIVATION_CODE
  echo
  [[ -n "$ACTIVATION_CODE" ]] || { echo "Activation key cannot be empty"; exit 1; }

  read -rp "How many Traff instances to run? " INSTANCES
  [[ "$INSTANCES" =~ ^[0-9]+$ ]] && (( INSTANCES > 0 )) || { echo "Invalid instance count"; exit 1; }

  read -rp "ExpressVPN protocol (recommended: lightway_udp): " PROTOCOL
  PROTOCOL="${PROTOCOL:-lightway_udp}"

  for ((i=1; i<=INSTANCES; i++)); do
    ns="${BASE_NS}${i}"
    region="$(region_for_index "$i")"
    echo "[$i/$INSTANCES] region=$region ns=$ns"

    create_ns_with_veth "$i" "$ns" "$VETH_PREFIX"
    configure_expressvpn_in_ns "$i" "$ns" "$WORKDIR" "$ACTIVATION_CODE" "$PROTOCOL" "$region"

    inst_home="$WORKDIR/inst_${i}/home"
    ip netns exec "$ns" bash -lc "cd '$BASE_DIR'; export HOME='$inst_home'; ${APP_CMD[*]}" >"$WORKDIR/app_${i}.log" 2>&1 &
    echo $! >"$WORKDIR/app_${i}.pid"
  done

  echo "Started $INSTANCES Traff instance(s) with ExpressVPN isolation."
  wait
}

main "$@"
