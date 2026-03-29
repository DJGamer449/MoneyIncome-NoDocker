#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earn}"
WORKDIR="${WORKDIR:-/tmp/earnapp_expressvpn}"
mkdir -p "$WORKDIR"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/expressvpn_netns_common.sh"

cleanup() { cleanup_ns_batch "$BASE_NS" "$VETH_PREFIX" "$WORKDIR"; }
trap cleanup EXIT

main() {
  require_root_and_tools
  command -v earnapp >/dev/null 2>&1 || { echo "earnapp not found in PATH"; exit 1; }
  setup_nat_once

  read -rsp "Enter ExpressVPN activation key: " ACTIVATION_CODE
  echo
  [[ -n "$ACTIVATION_CODE" ]] || { echo "Activation key cannot be empty"; exit 1; }

  read -rp "How many EarnApp instances to run? " INSTANCES
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
    etc_dir="$inst_dir/etc_earnapp"
    mkdir -p "$etc_dir"
    uuid_file="$etc_dir/uuid"
    [[ -f "$uuid_file" ]] || cat /proc/sys/kernel/random/uuid > "$uuid_file"

    ip netns exec "$ns" unshare -m bash -lc "
      set -euo pipefail
      export HOME='$inst_home'
      mkdir -p /etc/earnapp
      mount --bind '$etc_dir' /etc/earnapp
      /usr/bin/earnapp start >/dev/null 2>&1 || true
      exec /usr/bin/earnapp run
    " >"$WORKDIR/app_${i}.log" 2>&1 &
    echo $! >"$WORKDIR/app_${i}.pid"
  done

  echo "Started $INSTANCES EarnApp instance(s) with ExpressVPN isolation."
  wait
}

main "$@"
