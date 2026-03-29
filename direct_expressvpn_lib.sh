#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-appns}"
VETH_PREFIX="${VETH_PREFIX:-app}"
WORKDIR="${WORKDIR:-/tmp/${BASE_NS}_multi}"
EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app/expressvpn/bin}"
EXPRESSVPN_DAEMON="${EXPRESSVPN_DAEMON:-$EXPRESSVPN_BIN_DIR/expressvpn-daemon}"
EXPRESSVPN_CTL="${EXPRESSVPN_CTL:-$EXPRESSVPN_BIN_DIR/expressvpnctl}"
EXPRESSVPN_PROTOCOL="${EXPRESSVPN_PROTOCOL:-lightway_udp}"
HOST_IF="${HOST_IF:-$(ip route | awk '/default/ {print $5; exit}') }"
HOST_IF="${HOST_IF:-eth0}"

DEFAULT_REGIONS=(
  usa-san-francisco usa-new-jersey-2 usa-lincoln-park usa-houston usa-tampa-1 usa-new-jersey-3 usa-brooklyn usa-denver
  usa-dallas usa-atlanta usa-seattle usa-miami-2 usa-salt-lake-city usa-santa-monica usa-washington-dc usa-new-jersey-1
  usa-boston usa-birmingham usa-anchorage usa-little-rock usa-bridgeport usa-wilmington usa-honolulu usa-boise
  usa-indianapolis usa-des-moines usa-wichita usa-louisville usa-new-orleans usa-portland-maine usa-baltimore usa-detroit
)

require_expressvpn_bins() {
  [[ -x "$EXPRESSVPN_DAEMON" && -x "$EXPRESSVPN_CTL" ]] || {
    echo "ExpressVPN binaries missing: $EXPRESSVPN_BIN_DIR" >&2
    exit 1
  }
}

ask_activation_if_needed() {
  if [[ -z "${EXPRESSVPN_ACTIVATION_CODE:-}" ]]; then
    read -rsp "Enter ExpressVPN activation key: " EXPRESSVPN_ACTIVATION_CODE
    echo
  fi
  [[ -n "$EXPRESSVPN_ACTIVATION_CODE" ]] || { echo "Activation key is required"; exit 1; }
}

choose_regions() {
  local count="$1"
  REGIONS=()
  local total="${#DEFAULT_REGIONS[@]}"
  local i def r choose_specific
  read -rp "Select specific region for each instance? [y/N]: " choose_specific
  for ((i=1;i<=count;i++)); do
    def="${DEFAULT_REGIONS[$(((i-1)%total))]}"
    if [[ "$choose_specific" =~ ^[Yy]$ ]]; then
      read -rp "Region for instance $i [$def]: " r
      REGIONS+=("${r:-$def}")
    else
      REGIONS+=("$def")
    fi
  done
}

setup_namespace() {
  local ns="$1" idx="$2"
  local host_veth="${VETH_PREFIX}h${idx}"
  local ns_veth="${VETH_PREFIX}n${idx}"
  local subnet="10.210.${idx}.0/24"
  ip netns del "$ns" 2>/dev/null || true
  ip netns add "$ns"
  ip link add "$host_veth" type veth peer name "$ns_veth"
  ip link set "$ns_veth" netns "$ns"
  ip addr add "10.210.${idx}.1/24" dev "$host_veth" 2>/dev/null || true
  ip link set "$host_veth" up
  ip netns exec "$ns" ip addr add "10.210.${idx}.2/24" dev "$ns_veth"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_veth" up
  ip netns exec "$ns" ip route replace default via "10.210.${idx}.1"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  iptables -t nat -C POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
}

start_expressvpn_in_ns() {
  local ns="$1" region="$2"
  local rt="/tmp/expressvpn/${ns}"
  mkdir -p "$rt/home" "$rt/run" "$rt/tmp"
  ip netns exec "$ns" bash -lc "
    groupadd -f expressvpn >/dev/null 2>&1 || true
    export HOME='$rt/home' TMPDIR='$rt/tmp' XDG_RUNTIME_DIR='$rt/run' PATH='$EXPRESSVPN_BIN_DIR':\$PATH
    nohup '$EXPRESSVPN_DAEMON' >'$rt/daemon.log' 2>&1 &
    sleep 2
    '$EXPRESSVPN_CTL' background enable
    '$EXPRESSVPN_CTL' set networklock true
    '$EXPRESSVPN_CTL' set region '$region'
    '$EXPRESSVPN_CTL' set protocol '$EXPRESSVPN_PROTOCOL'
    '$EXPRESSVPN_CTL' login <(echo '$EXPRESSVPN_ACTIVATION_CODE')
    '$EXPRESSVPN_CTL' connect
  "
}
