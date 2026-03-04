#!/usr/bin/env bash
set -euo pipefail

# direct_wipter.sh
# Run multiple Wipter instances (one per proxy) in isolated network namespaces with tun2socks
# Usage: sudo ./direct_wipter.sh proxies.txt
#
# Expects:
# - tun2socks in PATH
# - You set WIPTER_EMAIL and WIPTER_PASSWORD in environment (or modify to read per-instance creds)
# - A WIPTER_DIR containing wipter.sh and wipter-app (default /opt/wipter). You can place the supplied wipter.sh there.
# - Behavior mirrors direct_earnapp.sh (policy routing + dns bypass). See that script for reference.

PROXY_FILE="${1:-proxies.txt}"

# Config (tweak if needed)
CHECK_WORKING="${CHECK_WORKING:-1}"     # 1=check proxy works, 0=skip
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_clones}"
WIPTER_DIR="${WIPTER_DIR:./app/wipter/}"   # Put your wipter.sh and wipter-app here (or adjust)
mkdir -p "$WORKDIR"

# tun/proxy settings
FWMARK="${FWMARK:-0x22b}"
TUN_TABLE="${TUN_TABLE:-100}"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 $PROXY_FILE"
    exit 1
  fi
  command -v tun2socks >/dev/null 2>&1 || { echo "tun2socks not found in PATH"; exit 1; }
}

# simple proxy checker (using curl through proxy)
check_proxy() {
  local proxy="$1"
  local p="$proxy"
  if [[ "$p" == socks5://* ]]; then
    p="socks5h://${p#socks5://}"
  fi
  if ! curl -fsS --proxy "$p" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" "http://1.1.1.1" >/dev/null; then
    echo "FAIL"
    return 1
  fi
  echo "OK"
  return 0
}

# parse proxy (same form as earnapp)
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
  case "$proto" in
    socks5|socks5h|http|https) ;;
    *) echo "UNSUPPORTED_PROTO"; return 1 ;;
  esac
  echo "$proto" "$user" "$pass" "$host" "$port"
}

# helper: compute subnet octets (kept similar to earnapp)
calc_octets() {
  local idx="$1"
  local B=$(( (idx-1) / 254 + 1 ))
  local C=$(( (idx-1) % 254 + 1 ))
  echo "$B" "$C"
}

# create namespace + veth pair (kept simple & compatible)
create_ns_with_veth() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local veth_host="${VETH_PREFIX}${idx}h"
  local veth_ns="${VETH_PREFIX}${idx}n"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true
  if ! ip link show "$veth_host" >/dev/null 2>&1; then
    ip link add "$veth_host" type veth peer name "$veth_ns"
  fi
  ip link set "$veth_ns" netns "$ns"
  ip addr add "10.${B}.${C}.1/24" dev "$veth_host" 2>/dev/null || true
  ip link set "$veth_host" up
  ip netns exec "$ns" ip addr add "10.${B}.${C}.2/24" dev "$veth_ns" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip netns exec "$ns" ip link set "$veth_ns" up 2>/dev/null || true || true
  ip netns exec "$ns" ip route replace default via "10.${B}.${C}.1" dev "$veth_ns" 2>/dev/null || true

  if [[ "$FORCE_NS_DNS" == "1" ]]; then
    mkdir -p "/etc/netns/$ns"
    : > "/etc/netns/$ns/resolv.conf"
    for d in $NS_DNS_LIST; do
      echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"
    done
  fi

  echo "$ns"
}

# route the proxy IP through the veth gateway so the proxy itself is reachable from inside ns
pin_proxy_route_in_ns() {
  local ns="$1"
  local idx="$2"
  local proxy_host="$3"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"
  local gw="10.${B}.${C}.1"
  local dev="${VETH_PREFIX}${idx}n"

  if [[ "$proxy_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip netns exec "$ns" ip route replace "$proxy_host/32" via "$gw" dev "$dev" || true
  else
    mapfile -t ips < <(getent ahostsv4 "$proxy_host" | awk '{print $1}' | sort -u)
    for ip in "${ips[@]}"; do
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done
  fi
}

# configure policy routing inside namespace to send marked traffic through tun0
configure_policy_routing() {
  local ns="$1"
  local idx="$2"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"
  local dev="${VETH_PREFIX}${idx}n"

  ip netns exec "$ns" ip route replace default via "10.${B}.${C}.1" dev "$dev" 2>/dev/null || true
  ip netns exec "$ns" ip route flush table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip route add default dev tun0 table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip rule add fwmark "$FWMARK" lookup main priority 100 2>/dev/null || true
  ip netns exec "$ns" ip rule add lookup "$TUN_TABLE" priority 200 2>/dev/null || true
}

# basic DNS bypassing via veth
bypass_dns_via_veth() {
  local ns="$1"
  local idx="$2"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"
  local gw="10.${B}.${C}.1"
  local dev="${VETH_PREFIX}${idx}n"
  local resolv="/etc/netns/$ns/resolv.conf"

  if [[ -f "$resolv" ]]; then
    while read -r _ ip; do
      [[ "${_:-}" == "nameserver" ]] || continue
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done < <(grep -E '^\s*nameserver\s+' "$resolv")
  else
    for ip in 1.1.1.1 8.8.8.8; do
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done
  fi
}

# start a single instance: create tun, start tun2socks, then start wipter inside namespace
start_tun2socks_and_wipter() {
  local idx="$1"
  local proxy="$2"

  local parsed proto user pass host port
  parsed="$(parse_proxy "$proxy")" || { echo "[$idx] Bad proxy: $proxy"; return 1; }
  read -r proto user pass host port <<<"$parsed"

  local ns
  ns="$(create_ns_with_veth "$idx")"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  # create tun0 inside ns and give it an IP (isolated)
  ip netns exec "$ns" ip tuntap add dev tun0 mode tun
  ip netns exec "$ns" ip addr add "198.18.${B}.${C}/30" dev tun0
  ip netns exec "$ns" ip link set tun0 up

  # make sure proxy IP is reachable via veth gateway
  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  # launch tun2socks inside the namespace, proxied to the proxy
  local t_pidfile="$WORKDIR/tun2socks_${idx}.pid"
  local t_logfile="$WORKDIR/tun2socks_${idx}.log"
  ip netns exec "$ns" bash -lc "
    nohup tun2socks -device tun0 -proxy '$proxy' -fwmark '$FWMARK' >'$t_logfile' 2>&1 &
    echo \$! > '$t_pidfile'
  "

  configure_policy_routing "$ns" "$idx"
  bypass_dns_via_veth "$ns" "$idx"

  # prepare per-instance filesystem for Wipter (simple bind of app dir)
  local inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"
  # copy or bind wipter app dir into instance dir (we bind mount at runtime)
  # Your real Wipter files should be in $WIPTER_DIR; ensure they exist
  if [[ ! -d "$WIPTER_DIR" ]]; then
    echo "WIPTER_DIR $WIPTER_DIR not found. Create and place wipter.sh + wipter-app there."
    return 1
  fi

  local w_pidfile="$WORKDIR/wipter_${idx}.pid"
  local w_logfile="$WORKDIR/wipter_${idx}.log"

  # start wipter entrypoint inside the netns with a private mount namespace so per-instance files can be bound
  ip netns exec "$ns" unshare -m bash -lc "
    set -m
    mount --make-rprivate / 2>/dev/null || true
    mkdir -p /opt/wipter
    mount --bind '$WIPTER_DIR' /opt/wipter
    export WIPTER_EMAIL='${WIPTER_EMAIL:-}'
    export WIPTER_PASSWORD='${WIPTER_PASSWORD:-}'
    cd /opt/wipter
    nohup bash ./wipter.sh >'$w_logfile' 2>&1 &
    echo \$! > '$w_pidfile'
  " &

  echo "[$idx] Started Wipter (ns=$ns). Logs: $w_logfile  tun2socks: $t_logfile"
}

# ensure NAT for namespaces to the world
setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  fi
  if ! iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  fi
  if ! iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  fi
}

cleanup() {
  echo
  echo "Cleaning up Wipter instances..."
  for f in "$WORKDIR"/wipter_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for f in "$WORKDIR"/tun2socks_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
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

  [[ -f "$PROXY_FILE" ]] || { echo "Proxy file not found: $PROXY_FILE"; exit 1; }
  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  (( ${#proxies[@]} > 0 )) || { echo "No proxies in $PROXY_FILE"; exit 1; }

  echo "Loaded ${#proxies[@]} proxies from $PROXY_FILE"

  local used=0
  for p in "${proxies[@]}"; do
    if [[ "$CHECK_WORKING" == "1" ]]; then
      res="$(check_proxy "$p" || true)"
      if [[ "$res" == "FAIL" ]]; then
        echo "[proxy] dead: $p"
        continue
      fi
    fi
    used=$((used+1))
    start_tun2socks_and_wipter "$used" "$p"
  done

  if (( used > 0 )); then
    echo "Wipter instances started ($used). Logs under $WORKDIR. Press Ctrl+C to stop."
    wait
  else
    echo "No usable proxies."
    exit 1
  fi
}

trap cleanup EXIT
main "$@"

