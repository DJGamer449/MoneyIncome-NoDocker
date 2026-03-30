#!/usr/bin/env bash
set -euo pipefail

BASE_NS="mystns"
VETH_PREFIX="myst"
WORKDIR="${WORKDIR:-/tmp/mysterium_expressvpn}"
EXPRESSVPN_ROOT="${EXPRESSVPN_ROOT:-/opt/expressvpn/mysterium_expressvpn}"
mkdir -p "$WORKDIR" "$EXPRESSVPN_ROOT"

SCRIPT_HOME="${PROJECT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
source "$SCRIPT_HOME/app/expressvpn/script/netns-instance.sh"

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
  command -v ip >/dev/null 2>&1 || { echo "iproute2 is required"; exit 1; }
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx-1) / 254 + 1 ))
  local c=$(( (idx-1) % 254 + 1 ))
  echo "$b" "$c"
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
}

create_ns_with_veth() {
  local idx="$1" ns="${BASE_NS}${idx}"
  local h="${VETH_PREFIX}${idx}h" n="${VETH_PREFIX}${idx}n"
  local b c; read -r b c <<<"$(calc_octets "$idx")"
  ip netns add "$ns" 2>/dev/null || true
  ip link add "$h" type veth peer name "$n" 2>/dev/null || true
  ip link set "$n" netns "$ns" 2>/dev/null || true
  ip addr add "10.${b}.${c}.1/24" dev "$h" 2>/dev/null || true
  ip link set "$h" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$n" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$n" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$n"
  echo "$ns"
}

start_instance() {
  local idx="$1" activation_key="$2"
  local ns; ns="$(create_ns_with_veth "$idx")"
  local region
  region="$(start_expressvpn_in_namespace "$ns" "$idx" "$activation_key" "$EXPRESSVPN_ROOT")"
  echo "[$idx] ExpressVPN connected in $ns region=$region"
  ip netns exec "$ns" bash -lc 'exec myst' >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#$BASE_NS}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}

main() {
  require_root
  setup_nat_once
  ACTIVATION_KEY="${EXPRESSVPN_ACTIVATION_KEY:-}"
  COUNT="${INSTANCE_COUNT:-}"
  if [[ -z "$ACTIVATION_KEY" ]]; then
    read -r -p "Enter ExpressVPN activation key: " ACTIVATION_KEY
  fi
  [[ -n "$ACTIVATION_KEY" ]] || { echo "Activation key is required"; exit 1; }
  if [[ -z "$COUNT" ]]; then
    read -r -p "How many instances do you want to run? " COUNT
  fi
  [[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "Invalid count"; exit 1; }
  (( COUNT > 0 )) || { echo "Count must be > 0"; exit 1; }
  for ((i=1;i<=COUNT;i++)); do
    start_instance "$i" "$ACTIVATION_KEY"
  done
  echo "All instances started with complete netns isolation. Logs: $WORKDIR"
  wait
}

trap cleanup EXIT
main "$@"
