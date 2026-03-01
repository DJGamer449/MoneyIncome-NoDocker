#!/usr/bin/env bash
set -euo pipefail

# ========= USER SETTINGS =========
# This script expects ANTGAIN_API_KEY to be exported from main.sh
APP_CMD=( env ANTGAIN_API_KEY="${ANTGAIN_API_KEY:-}" ./app/antgain )
PROXY_FILE="${1:-proxies.txt}"

# Toggle settings:
CHECK_WORKING="${CHECK_WORKING:-1}"
CHECK_SPEED="${CHECK_SPEED:-0}"
MAX_LAT_MS="${MAX_LAT_MS:-1500}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"

# Namespace & Directory Config
BASE_NS="${BASE_NS:-antns}"
VETH_PREFIX="${VETH_PREFIX:-ant}"
WORKDIR="${WORKDIR:-/tmp/antgain_multi}"
mkdir -p "$WORKDIR"

FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
FWMARK="${FWMARK:-0x22b}"
TUN_TABLE="${TUN_TABLE:-100}"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root."
    exit 1
  fi
  command -v tun2socks >/dev/null 2>&1 || { echo "tun2socks not found"; exit 1; }
}

calc_octets() {
  local idx="$1"
  local B=$(( (idx-1) / 254 + 1 ))
  local C=$(( (idx-1) % 254 + 1 ))
  echo "$B" "$C"
}

parse_proxy() {
  local line="$1"
  local proto rest creds hostport user pass host port
  proto="${line%%://*}"
  rest="${line#*://}"
  creds="${rest%@*}"
  hostport="${rest#*@}"
  user="${creds%%:*}"
  pass="${creds#*:}"
  host="${hostport%%:*}"
  port="${hostport#*:}"
  echo "$proto" "$user" "$pass" "$host" "$port"
}

check_proxy() {
  local proxy="$1"
  local start end ms
  local p="$proxy"
  [[ "$p" == socks5://* ]] && p="socks5h://${p#socks5://}"
  start="$(date +%s%3N)"
  if ! curl -fsS --proxy "$p" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" "http://1.1.1.1" >/dev/null; then
    return 1
  fi
  end="$(date +%s%3N)"
  ms=$(( end - start ))
  echo "OK ${ms}ms"
  return 0
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
}

create_ns_with_veth() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local veth_host="${VETH_PREFIX}${idx}h"
  local veth_ns="${VETH_PREFIX}${idx}n"
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
    echo "nameserver 1.1.1.1" > "/etc/netns/$ns/resolv.conf"
    echo "nameserver 8.8.8.8" >> "/etc/netns/$ns/resolv.conf"
  fi
  echo "$ns"
}

pin_proxy_route_in_ns() {
  local ns="$1" idx="$2" proxy_host="$3"
  local B C; read -r B C <<<"$(calc_octets "$idx")"
  local gw="10.${B}.${C}.1" dev="${VETH_PREFIX}${idx}n"
  if [[ "$proxy_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip netns exec "$ns" ip route replace "$proxy_host/32" via "$gw" dev "$dev" || true
  else
    mapfile -t ips < <(getent ahostsv4 "$proxy_host" | awk '{print $1}' | sort -u)
    for ip in "${ips[@]}"; do ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true; done
  fi
}

start_tun2socks_and_app() {
  local idx="$1" proxy="$2"
  local parsed; parsed="$(parse_proxy "$proxy")"
  read -r proto user pass host port <<<"$parsed"
  local ns; ns="$(create_ns_with_veth "$idx")"
  local B C; read -r B C <<<"$(calc_octets "$idx")"
  ip netns exec "$ns" ip tuntap add dev tun0 mode tun
  ip netns exec "$ns" ip addr add "198.18.${B}.${C}/30" dev tun0
  ip netns exec "$ns" ip link set tun0 up
  pin_proxy_route_in_ns "$ns" "$idx" "$host"
  ip netns exec "$ns" bash -c "tun2socks -device tun0 -proxy '$proxy' -fwmark '$FWMARK' >'$WORKDIR/tun2socks_${idx}.log' 2>&1 & echo \$! > '$WORKDIR/tun2socks_${idx}.pid'"
  
  # Policy Routing
  local gw="10.${B}.${C}.1" dev="${VETH_PREFIX}${idx}n"
  ip netns exec "$ns" ip route replace default via "$gw" dev "$dev" 2>/dev/null || true
  ip netns exec "$ns" ip route add default dev tun0 table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip rule add fwmark "$FWMARK" lookup main priority 100 2>/dev/null || true
  ip netns exec "$ns" ip rule add lookup "$TUN_TABLE" priority 200 2>/dev/null || true

  echo "[$idx] Starting AntGain via $proxy"
  ip netns exec "$ns" bash -c "cd '$(pwd)'; export HOME='$WORKDIR/inst_${idx}'; ${APP_CMD[*]}" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

main() {
  require_root
  setup_nat_once
  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  local used=0
  for p in "${proxies[@]}"; do
    if [[ "$CHECK_WORKING" == "1" ]]; then
      check_proxy "$p" || continue
    fi
    used=$((used+1))
    start_tun2socks_and_app "$used" "$p"
  done
  wait
}
main "$@"
