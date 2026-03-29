#!/usr/bin/env bash
set -euo pipefail

APP_CMD=( ./app/cli start accept --token "nblQB8tNIf6aj1Hs51/SJXqflMy0x1jPnsT6kVcYB8s=" )
BASE_NS="${BASE_NS:-pxns}"
VETH_PREFIX="${VETH_PREFIX:-veth}"
WORKDIR="${WORKDIR:-/tmp/pxns_clones}"
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
mkdir -p "$WORKDIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMON_CANDIDATES=(
  "${EXPRESSVPN_COMMON_PATH:-}"
  "$SCRIPT_DIR/expressvpn_common.sh"
  "$(pwd)/expressvpn_common.sh"
)
for candidate in "${COMMON_CANDIDATES[@]}"; do
  [[ -n "$candidate" && -f "$candidate" ]] || continue
  # shellcheck disable=SC1090
  source "$candidate"
  break
done
if ! declare -F ensure_expressvpn_installed >/dev/null 2>&1; then
  echo "expressvpn_common.sh not found. Set EXPRESSVPN_COMMON_PATH or place the file next to this script."
  exit 1
fi

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
  ensure_expressvpn_installed
}

calc_octets() {
  local idx="$1"
  local B=$(( (idx-1) / 254 + 1 ))
  local C=$(( (idx-1) % 254 + 1 ))
  echo "$B" "$C"
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

create_ns_with_veth() {
  local idx="$1" ns="${BASE_NS}${idx}" veth_host="${VETH_PREFIX}${idx}h" veth_ns="${VETH_PREFIX}${idx}n"
  local B C; read -r B C <<<"$(calc_octets "$idx")"
  ip netns add "$ns" 2>/dev/null || true
  ip link show "$veth_host" >/dev/null 2>&1 || ip link add "$veth_host" type veth peer name "$veth_ns"
  ip link set "$veth_ns" netns "$ns"
  ip addr add "10.${B}.${C}.1/24" dev "$veth_host" 2>/dev/null || true
  ip link set "$veth_host" up
  ip netns exec "$ns" ip addr add "10.${B}.${C}.2/24" dev "$veth_ns" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip route replace default via "10.${B}.${C}.1" dev "$veth_ns"
  if [[ "$FORCE_NS_DNS" == "1" ]]; then
    mkdir -p "/etc/netns/$ns"
    : > "/etc/netns/$ns/resolv.conf"
    for d in $NS_DNS_LIST; do echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"; done
  fi
  setup_ns_expressvpn_group "$ns"
  echo "$ns"
}

start_expressvpn_and_app() {
  local idx="$1" ns region
  ns="$(create_ns_with_veth "$idx")"
  region="$(region_for_instance "$idx")"
  local vpn_pidfile="$WORKDIR/expressvpn_${idx}.pid" vpn_logfile="$WORKDIR/expressvpn_${idx}.log"
  local svc_script="$WORKDIR/expressvpn-service-${idx}"
  create_expressvpn_service_script "$svc_script" "$idx"

  ip netns exec "$ns" bash -lc "mkdir -p /etc/init.d && cp '$svc_script' /etc/init.d/expressvpn-service && chmod 755 /etc/init.d/expressvpn-service"

  ip netns exec "$ns" bash -lc "
    ln -sfn /opt/expressvpn /expressvpn
    export CODE='$CODE'
    export SERVER='$region'
    export INSTANCE_ID='$idx'
    cd /opt/expressvpn
    ./start.sh >'$vpn_logfile' 2>&1 &
    echo \$! > '$vpn_pidfile'
  "

  ip netns exec "$ns" bash -lc 'for i in {1..120}; do ip -o link show | grep -q "tun" && exit 0; sleep 1; done; exit 1' || {
    echo "[$idx] ExpressVPN tunnel interface not detected"
    return 1
  }

  local inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"
  echo "[$idx] Starting app in netns=$ns region=$region"
  ip netns exec "$ns" bash -lc "cd '$(pwd)'; export HOME='$inst_dir'; ${APP_CMD[*]}" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  echo
  echo "Cleaning up..."
  for f in "$WORKDIR"/app_*.pid "$WORKDIR"/expressvpn_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#${BASE_NS}}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}
trap cleanup EXIT

main() {
  require_root
  setup_nat_once
  prompt_expressvpn_inputs

  local used=0
  while (( used < INSTANCE_COUNT )); do
    used=$((used+1))
    start_expressvpn_and_app "$used"
  done

  echo "Started $used instance(s). Logs in $WORKDIR"
  wait
}

main "$@"
