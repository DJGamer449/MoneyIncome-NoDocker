#!/usr/bin/env bash
set -euo pipefail

APP_CMD=( ./app/provider provide )
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-ur}"
WORKDIR="${WORKDIR:-/tmp/ur_clones}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPRESSVPNCTL="${EXPRESSVPNCTL:-$BASE_DIR/app/expressvpn/bin/expressvpnctl}"

mkdir -p "$WORKDIR"
source "$BASE_DIR/expressvpn_regions.sh"

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }
  [[ -x "$EXPRESSVPNCTL" ]] || { echo "expressvpnctl not executable: $EXPRESSVPNCTL"; exit 1; }
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

calc_octets() { local idx="$1"; echo $(( (idx-1)/254 + 1 )) $(( (idx-1)%254 + 1 )); }

create_ns_with_veth() {
  local idx="$1" ns="${BASE_NS}${idx}" veth_host="${VETH_PREFIX}${idx}h" veth_ns="${VETH_PREFIX}${idx}n" b c
  read -r b c <<<"$(calc_octets "$idx")"
  ip netns add "$ns" 2>/dev/null || true
  ip link show "$veth_host" >/dev/null 2>&1 || ip link add "$veth_host" type veth peer name "$veth_ns"
  ip link set "$veth_ns" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$veth_host" 2>/dev/null || true
  ip link set "$veth_host" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$veth_ns" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$veth_ns"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  echo "$ns"
}

login_expressvpn() {
  local key
  read -r -s -p "Enter ExpressVPN activation key/token: " key
  echo
  [[ -n "$key" ]] || { echo "Activation key cannot be empty"; exit 1; }
  local key_file="$WORKDIR/expressvpn_token.txt"
  printf '%s' "$key" > "$key_file"
  chmod 600 "$key_file"
  "$EXPRESSVPNCTL" login "$key_file"
}

connect_ns_vpn() {
  local idx="$1" ns="$2" alias_count="${#EXPRESSVPN_ALIASES[@]}" region
  region="${EXPRESSVPN_ALIASES[$(( (idx-1) % alias_count ))]}"
  local log="$WORKDIR/expressvpn_${idx}.log"
  echo "[$idx] Region=$region"
  ip netns exec "$ns" "$EXPRESSVPNCTL" set networklock false >>"$log" 2>&1 || true
  ip netns exec "$ns" "$EXPRESSVPNCTL" set region "$region" >>"$log" 2>&1
  ip netns exec "$ns" "$EXPRESSVPNCTL" connect >>"$log" 2>&1
  ip netns exec "$ns" "$EXPRESSVPNCTL" status | tee -a "$log"
}

start_instance() {
  local idx="$1" ns inst_dir
  ns="$(create_ns_with_veth "$idx")"
  connect_ns_vpn "$idx" "$ns"
  inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"
  [[ -d "/root/.urnetwork" ]] && cp -r "/root/.urnetwork" "$inst_dir/" || true
  echo "[$idx] Starting UrNetwork in $ns"
  ip netns exec "$ns" env -i HOME="$inst_dir" PATH="$PATH" bash -lc "cd '$BASE_DIR'; ${APP_CMD[*]}" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  echo "Cleaning up..."
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#${BASE_NS}}"
    ip netns exec "$ns" "$EXPRESSVPNCTL" disconnect >/dev/null 2>&1 || true
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}

trap cleanup EXIT

main() {
  require_root
  setup_nat_once
  login_expressvpn
  local total
  read -r -p "How many UrNetwork instances do you want to run? " total
  [[ "$total" =~ ^[0-9]+$ ]] || { echo "Invalid number: $total"; exit 1; }
  (( total > 0 )) || { echo "Instance count must be > 0"; exit 1; }
  for ((i=1; i<=total; i++)); do start_instance "$i"; done
  echo "Started $total UrNetwork instance(s). Ctrl+C to stop."
  wait
}

main "$@"
