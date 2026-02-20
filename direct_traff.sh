#!/usr/bin/env bash
set -euo pipefail

# ========= USER SETTINGS =========
#APP_CMD=(env CID="${CID:-<token>}" PS_IS_DOCKER="true" ./psclient )
APP_CMD=( ./cli start accept --token "<token>" )
PROXY_FILE="${1:-proxies.txt}"

# Toggle checks:
CHECK_WORKING="${CHECK_WORKING:-1}"     # 1=check proxy works before use, 0=skip
CHECK_SPEED="${CHECK_SPEED:-0}"         # 1=measure latency and filter, 0=skip
MAX_LAT_MS="${MAX_LAT_MS:-1500}"        # if CHECK_SPEED=1, reject slower than this (1500ms recommended)

CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"

# DNS: per-namespace resolv.conf + bypass tun2socks for those nameservers
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"        # keep 1
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"  # space-separated

BASE_NS="pxns"
WORKDIR="${WORKDIR:-/tmp/pxns_clones}"
mkdir -p "$WORKDIR"

# === MATCH xjasonlyu/tun2socks docker ===
FWMARK="${FWMARK:-0x22b}"

# Routing:
# - main table stays DIRECT via veth (like the docker container's eth0 route)
# - TUN_TABLE gets default via tun0
TUN_TABLE="${TUN_TABLE:-100}"
BYPASS_UDP53="${BYPASS_UDP53:-1}"     # 1=send UDP/53 (DNS) direct (recommended for HTTP proxies)
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-0}" # 1=send ALL UDP direct (leaks UDP outside proxy)


require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 $PROXY_FILE"
    exit 1
  fi
  command -v tun2socks >/dev/null 2>&1 || { echo "tun2socks not found in PATH"; exit 1; }
}

# Map instance index -> per-instance IPv4s without hitting the 0..255 octet limit.
# Supports up to 254*254 = 64516 instances.
# Host veth: 10.B.C.1/24
# NS   veth: 10.B.C.2/24
# TUN address: 198.18.B.C/30
calc_octets() {
  local idx="$1"
  local B=$(( (idx-1) / 254 + 1 ))
  local C=$(( (idx-1) % 254 + 1 ))
  echo "$B" "$C"
}

# Parse protocol://user:pass@ip:port
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

# Reliable proxy check:
# - avoids DNS by using http://1.1.1.1
# - upgrades socks5:// to socks5h:// to reduce DNS weirdness in curl
check_proxy() {
  local proxy="$1"
  local start end ms

  local p="$proxy"
  if [[ "$p" == socks5://* ]]; then
    p="socks5h://${p#socks5://}"
  fi

  start="$(date +%s%3N)"

  if ! curl -fsS \
    --proxy "$p" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$TOTAL_TIMEOUT" \
    "http://1.1.1.1" >/dev/null; then
    echo "FAIL"
    return 1
  fi

  end="$(date +%s%3N)"
  ms=$(( end - start ))

  if [[ "$CHECK_SPEED" == "1" ]] && (( ms > MAX_LAT_MS )); then
    echo "SLOW ${ms}ms"
    return 2
  fi

  echo "OK ${ms}ms"
  return 0
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # NAT for veth subnet (10.0.0.0/8 covers our generated 10.B.C.x addresses)
  if ! iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  fi

  # Forward allow (common missing piece on VPN boxes)
  if ! iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  fi
  if ! iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  fi
}

create_ns_with_veth() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local veth_host="veth${idx}h"
  local veth_ns="veth${idx}n"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  
# --- HARD RESET NAMESPACE ---
ip netns del "$ns" 2>/dev/null || true
ip link del "$veth_host" 2>/dev/null || true
ip link del "$veth_ns" 2>/dev/null || true
ip netns add "$ns" 2>/dev/null || true


  if ! ip link show "$veth_host" >/dev/null 2>&1; then
    ip link add "$veth_host" type veth peer name "$veth_ns"
  fi
  ip link set "$veth_ns" netns "$ns"

  ip addr add "10.${B}.${C}.1/24" dev "$veth_host" 2>/dev/null || true
  ip link set "$veth_host" up

  ip netns exec "$ns" ip addr add "10.${B}.${C}.2/24" dev "$veth_ns" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_ns" up

  # Temporary default route via host (so tun2socks can reach proxy server)
  ip netns exec "$ns" ip route replace default via "10.${B}.${C}.1" dev "$veth_ns"

  # Per-namespace resolv.conf (recommended)
  if [[ "$FORCE_NS_DNS" == "1" ]]; then
    mkdir -p "/etc/netns/$ns"
    : > "/etc/netns/$ns/resolv.conf"
    for d in $NS_DNS_LIST; do
      echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"
    done
  fi

  echo "$ns"
}

pin_proxy_route_in_ns() {
  local ns="$1"
  local idx="$2"
  local proxy_host="$3"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  local gw="10.${B}.${C}.1"
  local dev="veth${idx}n"

  # Ensure reaching proxy server bypasses tun (avoid loop)
  if [[ "$proxy_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip netns exec "$ns" ip route replace "$proxy_host/32" via "$gw" dev "$dev" || true
  else
    mapfile -t ips < <(getent ahostsv4 "$proxy_host" | awk '{print $1}' | sort -u)
    for ip in "${ips[@]}"; do
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done
  fi
}

# route nameserver IPs via veth (direct) so DNS works even if tun2socks/proxy UDP is bad
bypass_dns_via_veth() {
  local ns="$1"
  local idx="$2"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  local gw="10.${B}.${C}.1"
  local dev="veth${idx}n"
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

# IMPORTANT: ensure namespace firewall does NOT block UDP (or anything).
reset_ns_firewall_allow_all() {
  local ns="$1"
  ip netns exec "$ns" sh -c '
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -t raw -F 2>/dev/null || true
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
  '
}

configure_policy_routing() {
  local ns="$1"
  local idx="$2"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"
  local gw="10.${B}.${C}.1"
  local dev="veth${idx}n"

  # Keep MAIN table = direct via veth (same idea as docker container)
  ip netns exec "$ns" ip route replace default via "$gw" dev "$dev" 2>/dev/null || true

  # TUN_TABLE = everything else via tun0
  ip netns exec "$ns" ip route flush table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip route add default dev tun0 table "$TUN_TABLE" 2>/dev/null || true

  # Rule order matters (lower priority number = earlier)
  # 1) tun2socks' own marked sockets must go DIRECT (avoid proxy loop)
  ip netns exec "$ns" ip rule add fwmark "$FWMARK" lookup main priority 100 2>/dev/null || true

  # 2) DNS (UDP/53) must go DIRECT for HTTP proxies (no UDP support)
  if [[ "$BYPASS_ALL_UDP" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp lookup main priority 101 2>/dev/null || true
  elif [[ "$BYPASS_UDP53" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp dport 53 lookup main priority 101 2>/dev/null || true
    # keep the original docker-style rule too (harmless, helps some stub-resolver flows)
    ip netns exec "$ns" ip rule add iif lo ipproto udp dport 53 lookup main priority 102 2>/dev/null || true
  fi

  # 3) Everything else goes through tun0 (via TUN_TABLE)
  ip netns exec "$ns" ip rule add lookup "$TUN_TABLE" priority 200 2>/dev/null || true
}


start_tun2socks_and_app() {
  local idx="$1"
  local proxy="$2"

  local parsed proto user pass host port
  parsed="$(parse_proxy "$proxy")" || { echo "[$idx] Bad proxy: $proxy"; return 1; }
  read -r proto user pass host port <<<"$parsed"

  local ns
  ns="$(create_ns_with_veth "$idx")"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  # Create TUN inside namespace
  
# --- SAFE TUN RESET ---
ip netns exec "$ns" ip link del tun0 2>/dev/null || true
ip netns exec "$ns" ip tuntap add dev tun0 mode tun 2>/dev/null || true

  ip netns exec "$ns" ip addr add "198.18.${B}.${C}/30" dev tun0
  ip netns exec "$ns" ip link set tun0 up

  # Avoid proxy-loop
  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  # Start tun2socks in namespace (ADD FWMARK + LOG FILE)
  local t_pidfile="$WORKDIR/tun2socks_${idx}.pid"
  local t_logfile="$WORKDIR/tun2socks_${idx}.log"
  ip netns exec "$ns" bash -c "
    tun2socks -device tun0 -proxy '$proxy' -fwmark '$FWMARK' >'$t_logfile' 2>&1 &
    echo \$! > '$t_pidfile'
  "

  # Policy routing (docker-style): keep main=direct, send most traffic to tun0 via table
  configure_policy_routing "$ns" "$idx"

  # (Optional) extra safety: force nameserver IPs direct via veth
  bypass_dns_via_veth "$ns" "$idx"

  # Make sure firewall allows ALL (including UDP)
  reset_ns_firewall_allow_all "$ns"

  # Per-instance HOME to avoid collisions
  local inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"

  echo "[$idx] Starting app via proxy=$proxy (netns=$ns)"
  ip netns exec "$ns" bash -c "cd '$(pwd)'; export HOME='$inst_dir'; ${APP_CMD[*]}" \
    >"$WORKDIR/app_${idx}.log" 2>&1 &

  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  echo
  echo "Cleaning up..."
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for f in "$WORKDIR"/tun2socks_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done

  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#${BASE_NS}}"
    ip link del "veth${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}
trap cleanup EXIT

main() {
  require_root
  setup_nat_once

  [[ -f "$PROXY_FILE" ]] || { echo "Proxy file not found: $PROXY_FILE"; exit 1; }

  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  (( ${#proxies[@]} > 0 )) || { echo "No proxies in $PROXY_FILE"; exit 1; }

  echo "Loaded ${#proxies[@]} proxies from $PROXY_FILE"
  echo "FWMARK=$FWMARK"
  echo "CHECK_WORKING=$CHECK_WORKING CHECK_SPEED=$CHECK_SPEED MAX_LAT_MS=$MAX_LAT_MS"
  echo "FORCE_NS_DNS=$FORCE_NS_DNS NS_DNS_LIST='$NS_DNS_LIST'"

  local used=0
  local i=0
  for p in "${proxies[@]}"; do
    i=$((i+1))

    if [[ "$CHECK_WORKING" == "1" ]]; then
      res="$(check_proxy "$p" || true)"
      if [[ "$res" == FAIL* ]]; then
        echo "[src#$i] dead: $p"
        continue
      fi
      if [[ "$res" == SLOW* ]]; then
        echo "[src#$i] too slow ($res): $p"
        continue
      fi
      echo "[src#$i] ok ($res): $p"
    fi

    used=$((used+1))
    start_tun2socks_and_app "$used" "$p"
  done

  (( used > 0 )) || { echo "No usable proxies after filtering."; exit 1; }

  echo
  echo "Started $used clone(s). Logs:"
  echo "  $WORKDIR/app_*.log"
  echo "  $WORKDIR/tun2socks_*.log"
  echo "Ctrl+C to stop and cleanup."
  wait
}

main "$@"
