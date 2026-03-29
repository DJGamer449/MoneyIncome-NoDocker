#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_expressvpn}"
HONEYGAIN_DIR="${HONEYGAIN_DIR:-./app/honeygain_file}"
HONEYGAIN_BIN="${HONEYGAIN_BIN:-$HONEYGAIN_DIR/honeygain}"
HONEYGAIN_LIB_DIR="${HONEYGAIN_LIB_DIR:-$HONEYGAIN_DIR}"
HONEYGAIN_ACCOUNTS_RAW="${HONEYGAIN_ACCOUNTS:-}"
mkdir -p "$WORKDIR"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/expressvpn_netns_common.sh"

cleanup() { cleanup_ns_batch "$BASE_NS" "$VETH_PREFIX" "$WORKDIR"; }
trap cleanup EXIT

main() {
  require_root_and_tools
  [[ -x "$HONEYGAIN_BIN" ]] || { echo "Honeygain binary not executable: $HONEYGAIN_BIN"; exit 1; }
  [[ -n "$HONEYGAIN_ACCOUNTS_RAW" ]] || { echo "HONEYGAIN_ACCOUNTS is empty"; exit 1; }
  setup_nat_once

  mapfile -t ACCOUNTS < <(printf '%s\n' "$HONEYGAIN_ACCOUNTS_RAW" | sed '/^\s*$/d')
  (( ${#ACCOUNTS[@]} > 0 )) || { echo "No Honeygain accounts parsed"; exit 1; }

  read -rsp "Enter ExpressVPN activation key: " ACTIVATION_CODE
  echo
  [[ -n "$ACTIVATION_CODE" ]] || { echo "Activation key cannot be empty"; exit 1; }

  read -rp "How many Honeygain instances to run? " INSTANCES
  [[ "$INSTANCES" =~ ^[0-9]+$ ]] && (( INSTANCES > 0 )) || { echo "Invalid instance count"; exit 1; }

  read -rp "ExpressVPN protocol (recommended: lightway_udp): " PROTOCOL
  PROTOCOL="${PROTOCOL:-lightway_udp}"

  for ((i=1; i<=INSTANCES; i++)); do
    ns="${BASE_NS}${i}"
    region="$(region_for_index "$i")"
    acct="${ACCOUNTS[$(((i-1)%${#ACCOUNTS[@]}))]}"
    email="${acct%%|*}"
    password="${acct#*|}"
    device_name="hg-${i}"

    echo "[$i/$INSTANCES] region=$region ns=$ns account=$email"
    create_ns_with_veth "$i" "$ns" "$VETH_PREFIX"
    configure_expressvpn_in_ns "$i" "$ns" "$WORKDIR" "$ACTIVATION_CODE" "$PROTOCOL" "$region"

    inst_home="$WORKDIR/inst_${i}/home"
    ip netns exec "$ns" bash -lc "
      cd '$BASE_DIR'
      export HOME='$inst_home'
      export LD_LIBRARY_PATH='$HONEYGAIN_LIB_DIR:\${LD_LIBRARY_PATH:-}'
      exec '$HONEYGAIN_BIN' -tou-accept -email '$email' -pass '$password' -device '$device_name'
    " >"$WORKDIR/app_${i}.log" 2>&1 &
    echo $! >"$WORKDIR/app_${i}.pid"
  done

  echo "Started $INSTANCES Honeygain instance(s) with ExpressVPN isolation."
  wait
}

main "$@"
