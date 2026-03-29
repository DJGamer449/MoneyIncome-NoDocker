#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-myster}"
WORKDIR="${WORKDIR:-/tmp/mysterium_expressvpn}"
MYST_BIN="${MYST_BIN:-$(command -v myst 2>/dev/null || true)}"
MYST_BASE_DIR="${MYST_BASE_DIR:-$(pwd)/myst}"
MYST_TERMS_FLAG="${MYST_TERMS_FLAG:---agreed-terms-and-conditions}"
MYST_EXTRA_ARGS="${MYST_EXTRA_ARGS:-}"
mkdir -p "$WORKDIR" "$MYST_BASE_DIR"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/expressvpn_netns_common.sh"

cleanup() { cleanup_ns_batch "$BASE_NS" "$VETH_PREFIX" "$WORKDIR"; }
trap cleanup EXIT

main() {
  require_root_and_tools
  [[ -n "$MYST_BIN" && -x "$MYST_BIN" ]] || { echo "myst binary not found"; exit 1; }
  setup_nat_once

  read -rsp "Enter ExpressVPN activation key: " ACTIVATION_CODE
  echo
  [[ -n "$ACTIVATION_CODE" ]] || { echo "Activation key cannot be empty"; exit 1; }

  read -rp "How many Mysterium instances to run? " INSTANCES
  [[ "$INSTANCES" =~ ^[0-9]+$ ]] && (( INSTANCES > 0 )) || { echo "Invalid instance count"; exit 1; }

  read -rp "ExpressVPN protocol (recommended: lightway_udp): " PROTOCOL
  PROTOCOL="${PROTOCOL:-lightway_udp}"

  for ((i=1; i<=INSTANCES; i++)); do
    ns="${BASE_NS}${i}"
    region="$(region_for_index "$i")"
    data_dir="$MYST_BASE_DIR/myst-$i"
    mkdir -p "$data_dir"

    echo "[$i/$INSTANCES] region=$region ns=$ns"
    create_ns_with_veth "$i" "$ns" "$VETH_PREFIX"
    configure_expressvpn_in_ns "$i" "$ns" "$WORKDIR" "$ACTIVATION_CODE" "$PROTOCOL" "$region"

    inst_home="$WORKDIR/inst_${i}/home"
    ip netns exec "$ns" unshare -m bash -lc "
      set -euo pipefail
      export HOME='$inst_home'
      mkdir -p /root/.mysterium-node
      mount --bind '$data_dir' /root/.mysterium-node
      cd '$BASE_DIR'
      exec '$MYST_BIN' run '$MYST_TERMS_FLAG' $MYST_EXTRA_ARGS
    " >"$WORKDIR/app_${i}.log" 2>&1 &
    echo $! >"$WORKDIR/app_${i}.pid"
  done

  echo "Started $INSTANCES Mysterium instance(s) with ExpressVPN isolation."
  wait
}

main "$@"
