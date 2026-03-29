#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_expressvpn}"
WIPTER_DIR="${WIPTER_DIR:-./app/wipter}"
mkdir -p "$WORKDIR"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/expressvpn_netns_common.sh"

cleanup() { cleanup_ns_batch "$BASE_NS" "$VETH_PREFIX" "$WORKDIR"; }
trap cleanup EXIT

main() {
  require_root_and_tools
  [[ -d "$WIPTER_DIR" ]] || { echo "WIPTER_DIR not found: $WIPTER_DIR"; exit 1; }
  [[ -n "${WIPTER_EMAIL:-}" && -n "${WIPTER_PASSWORD:-}" ]] || { echo "WIPTER_EMAIL/WIPTER_PASSWORD must be set"; exit 1; }
  setup_nat_once

  read -rsp "Enter ExpressVPN activation key: " ACTIVATION_CODE
  echo
  [[ -n "$ACTIVATION_CODE" ]] || { echo "Activation key cannot be empty"; exit 1; }

  read -rp "How many Wipter instances to run? " INSTANCES
  [[ "$INSTANCES" =~ ^[0-9]+$ ]] && (( INSTANCES > 0 )) || { echo "Invalid instance count"; exit 1; }

  read -rp "ExpressVPN protocol (recommended: lightway_udp): " PROTOCOL
  PROTOCOL="${PROTOCOL:-lightway_udp}"

  for ((i=1; i<=INSTANCES; i++)); do
    ns="${BASE_NS}${i}"
    region="$(region_for_index "$i")"
    echo "[$i/$INSTANCES] region=$region ns=$ns"

    create_ns_with_veth "$i" "$ns" "$VETH_PREFIX"
    configure_expressvpn_in_ns "$i" "$ns" "$WORKDIR" "$ACTIVATION_CODE" "$PROTOCOL" "$region"

    inst_dir="$WORKDIR/inst_${i}"
    inst_home="$inst_dir/home"
    ip netns exec "$ns" unshare -m bash -lc "
      set -euo pipefail
      export HOME='$inst_home'
      mkdir -p /opt/wipter
      mount --bind '$WIPTER_DIR' /opt/wipter
      cd /opt/wipter
      export WIPTER_EMAIL='$WIPTER_EMAIL'
      export WIPTER_PASSWORD='$WIPTER_PASSWORD'
      exec bash ./wipter.sh
    " >"$WORKDIR/app_${i}.log" 2>&1 &
    echo $! >"$WORKDIR/app_${i}.pid"
  done

  echo "Started $INSTANCES Wipter instance(s) with ExpressVPN isolation."
  wait
}

main "$@"
