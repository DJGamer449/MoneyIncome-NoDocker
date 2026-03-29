#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_CMD=( ./app/provider provide )
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-urn}"
WORKDIR="${WORKDIR:-/tmp/urnetwork_expressvpn}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$SCRIPT_DIR/app/expressvpn/bin}"
EXPRESSVPN_PROTOCOL="${EXPRESSVPN_PROTOCOL:-lightway_udp}"
mkdir -p "$WORKDIR"

REGIONS=(
"usa-san-francisco" "usa-new-jersey-2" "usa-lincoln-park" "usa-houston" "usa-tampa-1" "usa-new-jersey-3" "usa-brooklyn" "usa-denver"
"usa-dallas" "usa-atlanta" "usa-seattle" "usa-miami-2" "usa-salt-lake-city" "usa-santa-monica" "usa-washington-dc" "usa-new-jersey-1"
"usa-boston" "usa-birmingham" "usa-anchorage" "usa-little-rock" "usa-bridgeport" "usa-wilmington" "usa-honolulu" "usa-boise"
"usa-indianapolis" "usa-des-moines" "usa-wichita" "usa-louisville" "usa-new-orleans" "usa-portland-maine" "usa-baltimore" "usa-detroit"
"usa-minneapolis" "usa-jackson" "usa-st.-louis" "usa-billings" "usa-omaha" "usa-las-vegas" "usa-manchester" "usa-charlotte"
"usa-fargo" "usa-columbus" "usa-oklahoma-city" "usa-portland-oregon" "usa-philadelphia" "usa-providence"
"usa-charleston-south-carolina" "usa-sioux-falls" "usa-nashville" "usa-burlington" "usa-virginia-beach"
"usa-charleston-west-virginia" "usa-milwaukee" "usa-cheyenne" "usa-miami" "usa-los-angeles-1" "usa-los-angeles-2"
"usa-los-angeles-5" "usa-los-angeles-3" "usa-new-york" "usa-chicago" "usa-phoenix" "usa-albuquerque"
"costa-rica" "thailand" "greece" "france-strasbourg" "france-paris-1" "france-alsace" "france-marseille" "france-paris-2"
"israel" "iceland" "singapore-cbd" "singapore-jurong" "singapore-marina-bay" "taiwan-3" "south-africa" "switzerland" "switzerland-2"
"bulgaria" "malaysia" "indonesia" "new-zealand" "hong-kong-2" "hong-kong-1" "bahamas" "vietnam"
"croatia" "liechtenstein" "luxembourg" "moldova" "slovenia" "latvia" "cyprus" "chile" "albania" "slovakia" "uzbekistan" "isle-of-man" "estonia"
"colombia" "mexico" "kazakhstan" "malta" "georgia" "mongolia" "algeria" "uruguay" "guatemala" "peru" "venezuela" "ecuador"
"serbia" "north-macedonia" "bosnia-and-herzegovina" "uk-midlands" "uk-east-london" "uk-tottenham" "uk-london" "uk-docklands" "uk-wembley"
"india-(via-uk)" "india-(via-singapore)"
"australia-melbourne" "australia-sydney-2" "australia-brisbane" "australia-perth" "australia-woolloomooloo" "australia-sydney" "australia-adelaide"
"italy-milan" "italy-cosenza" "italy-naples" "netherlands-rotterdam" "netherlands-the-hague" "netherlands-amsterdam"
"brazil-2" "brazil" "philippines" "canada-toronto-2" "canada-vancouver" "canada-montreal" "canada-toronto" "macau" "cambodia" "kenya"
"andorra" "armenia" "belarus" "monaco" "jersey" "montenegro" "bangladesh" "bhutan" "brunei" "laos" "myanmar" "nepal" "pakistan" "sri-lanka" "panama"
"sweden-2" "sweden" "austria" "germany-nuremberg" "germany-frankfurt-1" "germany-frankfurt-3" "spain-barcelona" "spain-madrid" "spain-barcelona-2"
"japan-yokohama" "japan-tokyo" "japan-shibuya" "japan-osaka" "bolivia" "guam" "ghana" "dominican-republic" "jamaica" "puerto-rico" "bermuda" "trinidad-and-tobago" "cayman-islands" "cuba" "honduras"
"lebanon" "morocco" "united-arab-emirates" "azerbaijan" "portugal" "poland" "ireland" "finland" "lithuania" "czech-republic" "south-korea-2" "denmark" "egypt" "belgium" "romania" "ukraine" "argentina" "turkey" "norway" "hungary"
)

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0"
    exit 1
  fi
  [[ -x "$EXPRESSVPN_BIN_DIR/expressvpnctl" ]] || { echo "expressvpnctl not found in $EXPRESSVPN_BIN_DIR"; exit 1; }
  [[ -x "$EXPRESSVPN_BIN_DIR/expressvpn-daemon" ]] || { echo "expressvpn-daemon not found in $EXPRESSVPN_BIN_DIR"; exit 1; }
}

ask_user_inputs() {
  ACTIVATION_CODE="${ACTIVATION_CODE:-}"
  INSTANCE_COUNT="${INSTANCE_COUNT:-}"

  if [[ -z "$ACTIVATION_CODE" ]]; then
    read -rsp "Enter ExpressVPN activation code/key: " ACTIVATION_CODE
    echo
  fi
  [[ -n "$ACTIVATION_CODE" ]] || { echo "Activation code is required."; exit 1; }

  if [[ ! "$INSTANCE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    while true; do
      read -rp "How many instances do you want to run? " INSTANCE_COUNT
      [[ "$INSTANCE_COUNT" =~ ^[1-9][0-9]*$ ]] && break
      echo "Please enter a valid number >= 1"
    done
  fi

  if [[ -n "${EXPRESSVPN_PROTOCOL_OVERRIDE:-}" ]]; then
    EXPRESSVPN_PROTOCOL="$EXPRESSVPN_PROTOCOL_OVERRIDE"
  else
    read -rp "ExpressVPN protocol [default: $EXPRESSVPN_PROTOCOL]: " proto_input
    EXPRESSVPN_PROTOCOL="${proto_input:-$EXPRESSVPN_PROTOCOL}"
  fi
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx-1) / 254 + 1 ))
  local c=$(( (idx-1) % 254 + 1 ))
  echo "$b" "$c"
}

region_for_index() {
  local idx="$1"
  local total="${#REGIONS[@]}"
  local zero_based=$(( (idx - 1) % total ))
  echo "${REGIONS[$zero_based]}"
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  fi
}

create_ns_with_veth() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local veth_host="${VETH_PREFIX}${idx}h"
  local veth_ns="${VETH_PREFIX}${idx}n"
  local b c
  read -r b c <<<"$(calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true
  if ! ip link show "$veth_host" >/dev/null 2>&1; then
    ip link add "$veth_host" type veth peer name "$veth_ns"
  fi
  ip link set "$veth_ns" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$veth_host" 2>/dev/null || true
  ip link set "$veth_host" up

  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$veth_ns" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$veth_ns"

  mkdir -p "/etc/netns/$ns"
  : > "/etc/netns/$ns/resolv.conf"
  for d in $NS_DNS_LIST; do
    echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"
  done

  echo "$ns"
}

setup_expressvpn_in_ns() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local region
  region="$(region_for_index "$idx")"
  local ev_dir="$WORKDIR/expressvpn_${idx}"
  local home_dir="$ev_dir/home"
  local run_dir="$ev_dir/run"
  mkdir -p "$home_dir" "$run_dir"

  echo "[$idx] Assigning region: $region"

  ip netns exec "$ns" bash -lc "
    set -e
    getent group expressvpn >/dev/null || groupadd -f expressvpn || true
    export HOME='$home_dir'
    export XDG_RUNTIME_DIR='$run_dir'
    export PATH='$EXPRESSVPN_BIN_DIR':\$PATH
    cd '$EXPRESSVPN_BIN_DIR'
    nohup ./expressvpn-daemon >'$WORKDIR/expressvpn_daemon_${idx}.log' 2>&1 &
    echo \$! > '$WORKDIR/expressvpn_daemon_${idx}.pid'
    sleep 2
    ./expressvpnctl background enable || true
    ./expressvpnctl set networklock true
    ./expressvpnctl set auto_connect true
    ./expressvpnctl set protocol '$EXPRESSVPN_PROTOCOL'
    ./expressvpnctl login <(echo '$ACTIVATION_CODE') || true
    ./expressvpnctl set region '$region'
    ./expressvpnctl connect '$region'
    ./expressvpnctl status > '$WORKDIR/expressvpn_status_${idx}.log' 2>&1 || true
  "
}

start_app_instance() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"

  echo "[$idx] Starting UrNetwork in netns=$ns"
  ip netns exec "$ns" bash -lc "cd '$(pwd)'; export HOME='$inst_dir'; ${APP_CMD[*]}" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  echo
  echo "Cleaning up..."
  for f in "$WORKDIR"/app_*.pid "$WORKDIR"/expressvpn_daemon_*.pid; do
    [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true
  done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#$BASE_NS}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}
trap cleanup EXIT

main() {
  require_root
  ask_user_inputs
  setup_nat_once

  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    create_ns_with_veth "$i" >/dev/null
    setup_expressvpn_in_ns "$i"
    start_app_instance "$i"
  done

  echo "Started $INSTANCE_COUNT UrNetwork instance(s) with per-namespace ExpressVPN."
  echo "Logs: $WORKDIR"
  wait
}

main "$@"
