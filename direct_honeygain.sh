#!/usr/bin/env bash
set -euo pipefail

PROXY_FILE="${1:-proxies.txt}"
CHECK_WORKING="${CHECK_WORKING:-1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
BASE_NS="${BASE_NS:-hgne}"
VETH_PREFIX="${VETH_PREFIX:-hgv}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
FWMARK="${FWMARK:-0x22b}"
TUN_TABLE="${TUN_TABLE:-100}"
BYPASS_UDP53="${BYPASS_UDP53:-1}"
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-1}"
HONEYGAIN_DIR="${HONEYGAIN_DIR:-./app/honeygain_file}"
HONEYGAIN_BIN="${HONEYGAIN_BIN:-$HONEYGAIN_DIR/honeygain}"
HONEYGAIN_LIB_DIR="${HONEYGAIN_LIB_DIR:-$HONEYGAIN_DIR}"
HONEYGAIN_ACCOUNTS_RAW="${HONEYGAIN_ACCOUNTS:-}"
DEVICES_PER_ACCOUNT=10

mkdir -p "$WORKDIR"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 $PROXY_FILE"
    exit 1
  fi
  command -v hev-socks5-tunnel >/dev/null 2>&1 || { echo "hev-socks5-tunnel not found in PATH"; exit 1; }
  [[ -x "$HONEYGAIN_BIN" ]] || { echo "Honeygain binary not executable: $HONEYGAIN_BIN"; exit 1; }
  [[ -n "$HONEYGAIN_ACCOUNTS_RAW" ]] || { echo "HONEYGAIN_ACCOUNTS is empty. Configure accounts in main.sh first."; exit 1; }
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
  case "$proto" in
    socks5|socks5h|http|https) ;;
    *) echo "UNSUPPORTED_PROTO"; return 1 ;;
  esac
  echo "$proto" "$user" "$pass" "$host" "$port"
}

check_proxy() {
  local proxy="$1"
  local p="$proxy"
  if [[ "$p" == socks5://* ]]; then
    p="socks5h://${p#socks5://}"
  fi
  curl -fsS --proxy "$p" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" "http://1.1.1.1" >/dev/null
}

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
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip route replace default via "10.${B}.${C}.1" dev "$veth_ns"
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
  local ns="$1" idx="$2" proxy_host="$3"
  local B C gw dev
  read -r B C <<<"$(calc_octets "$idx")"
  gw="10.${B}.${C}.1"
  dev="${VETH_PREFIX}${idx}n"
  if [[ "$proxy_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip netns exec "$ns" ip route replace "$proxy_host/32" via "$gw" dev "$dev" || true
  else
    mapfile -t ips < <(getent ahostsv4 "$proxy_host" | awk '{print $1}' | sort -u)
    for ip in "${ips[@]}"; do
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done
  fi
}

bypass_dns_via_veth() {
  local ns="$1" idx="$2"
  local B C gw dev resolv
  read -r B C <<<"$(calc_octets "$idx")"
  gw="10.${B}.${C}.1"
  dev="${VETH_PREFIX}${idx}n"
  resolv="/etc/netns/$ns/resolv.conf"
  if [[ -f "$resolv" ]]; then
    while read -r _ ip; do
      [[ "${_:-}" == "nameserver" ]] || continue
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done < <(grep -E '^\s*nameserver\s+' "$resolv")
  fi
}

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
  local ns="$1" idx="$2"
  local B C gw dev
  read -r B C <<<"$(calc_octets "$idx")"
  gw="10.${B}.${C}.1"
  dev="${VETH_PREFIX}${idx}n"
  ip netns exec "$ns" ip route replace default via "$gw" dev "$dev" 2>/dev/null || true
  ip netns exec "$ns" ip route flush table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip route add default dev tun0 table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip rule add fwmark "$FWMARK" lookup main priority 100 2>/dev/null || true
  if [[ "$BYPASS_ALL_UDP" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp lookup main priority 101 2>/dev/null || true
  elif [[ "$BYPASS_UDP53" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp dport 53 lookup main priority 101 2>/dev/null || true
    ip netns exec "$ns" ip rule add iif lo ipproto udp dport 53 lookup main priority 102 2>/dev/null || true
  fi
  ip netns exec "$ns" ip rule add lookup "$TUN_TABLE" priority 200 2>/dev/null || true
}

load_accounts() {
  mapfile -t HONEYGAIN_ACCOUNTS_LIST < <(printf '%s\n' "$HONEYGAIN_ACCOUNTS_RAW" | sed '/^\s*$/d')
  (( ${#HONEYGAIN_ACCOUNTS_LIST[@]} > 0 )) || { echo "No Honeygain accounts supplied."; exit 1; }
}

start_instance() {
  local idx="$1" proxy="$2" email="$3" password="$4" device_no="$5"
  local parsed proto user pass host port ns B C
  parsed="$(parse_proxy "$proxy")" || { echo "[$idx] Bad proxy: $proxy"; return 1; }
  read -r proto user pass host port <<<"$parsed"
  ns="$(create_ns_with_veth "$idx")"
  read -r B C <<<"$(calc_octets "$idx")"
  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  local t_pidfile="$WORKDIR/hev-socks5-tunnel_${idx}.pid"
  local t_logfile="$WORKDIR/hev-socks5-tunnel_${idx}.log"
  local t_cfgfile="$WORKDIR/hev-socks5-tunnel_${idx}.yml"
  local fwmark_dec=$((FWMARK))
  local tun_ip="198.18.${B}.${C}"

  if [[ "$proto" == "socks5h" ]]; then proto="socks5"; fi
  if [[ "$proto" != "socks5" ]]; then
    echo "[$idx] Unsupported proxy protocol for Honeygain/hev-socks5-tunnel: $proto"
    return 1
  fi

  cat >"$t_cfgfile" <<CFG

tunnel:
  name: tun0
  mtu: 8500
  ipv4: $tun_ip
socks5:
  address: $host
  port: $port
  udp: 'udp'
  username: '$user'
  password: '$pass'
  mark: $fwmark_dec
misc:
  log-file: stderr
  log-level: info
CFG

  ip netns exec "$ns" bash -c "hev-socks5-tunnel '$t_cfgfile' >'$t_logfile' 2>&1 & echo \$! > '$t_pidfile'"
  ip netns exec "$ns" bash -c 'for i in {1..50}; do ip link show tun0 >/dev/null 2>&1 && exit 0; sleep 0.1; done; exit 1' || {
    echo "[$idx] tun0 was not created by hev-socks5-tunnel"
    return 1
  }

  configure_policy_routing "$ns" "$idx"
  bypass_dns_via_veth "$ns" "$idx"
  reset_ns_firewall_allow_all "$ns"

  local inst_dir="$WORKDIR/inst_${idx}"
  local mailname="${email%@*}"
  local device_name="${mailname}-${device_no}"
  mkdir -p "$inst_dir"
  echo "[$idx] Starting Honeygain for $email as device $device_name via proxy=$proxy"
  ip netns exec "$ns" bash -c "cd '$(pwd)'; export HOME='$inst_dir'; export LD_LIBRARY_PATH='$HONEYGAIN_LIB_DIR:\${LD_LIBRARY_PATH:-}'; exec '$HONEYGAIN_BIN' -tou-accept -email '$email' -pass '$password' -device '$device_name'" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  echo
  echo "Cleaning up Honeygain..."
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for f in "$WORKDIR"/hev-socks5-tunnel_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
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
  load_accounts
  [[ -f "$PROXY_FILE" ]] || { echo "Proxy file not found: $PROXY_FILE"; exit 1; }
  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  (( ${#proxies[@]} > 0 )) || { echo "No proxies in $PROXY_FILE"; exit 1; }
  echo "Loaded ${#proxies[@]} proxies from $PROXY_FILE"
  echo "Honeygain accounts available: ${#HONEYGAIN_ACCOUNTS_LIST[@]}"

  local max_devices=$(( ${#HONEYGAIN_ACCOUNTS_LIST[@]} * DEVICES_PER_ACCOUNT ))
  if (( ${#proxies[@]} > max_devices )); then
    echo "Only $max_devices proxies can be used because each Honeygain account is limited to $DEVICES_PER_ACCOUNT devices. Extra proxies will be skipped."
  fi

  local used=0 account_index device_no entry email password p
  for p in "${proxies[@]}"; do
    if (( used >= max_devices )); then
      break
    fi
    if [[ "$CHECK_WORKING" == "1" ]] && ! check_proxy "$p"; then
      echo "[src] dead: $p"
      continue
    fi
    account_index=$(( used / DEVICES_PER_ACCOUNT ))
    device_no=$(( used % DEVICES_PER_ACCOUNT + 1 ))
    entry="${HONEYGAIN_ACCOUNTS_LIST[$account_index]}"
    email="${entry%%|*}"
    password="${entry#*|}"
    used=$((used+1))
    start_instance "$used" "$p" "$email" "$password" "$device_no"
  done

  (( used > 0 )) || { echo "No usable proxies after filtering."; exit 1; }
  echo
  echo "Started $used Honeygain instance(s). Logs:"
  echo "  $WORKDIR/app_*.log"
  echo "  $WORKDIR/hev-socks5-tunnel_*.log"
  echo "Ctrl+C to stop and cleanup."
  wait
}

main "$@"
