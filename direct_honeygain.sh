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
BYPASS_UDP53="${BYPASS_UDP53:-0}"
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-0}"
# Honeygain must not bypass UDP directly via the host, otherwise the app can expose the
# host IP instead of the proxy IP. Keep both disabled by default so all app traffic
# stays on tun0, while hev's own marked sockets still use the direct route.
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

  command -v hev-socks5-tunnel >/dev/null 2>&1 || {
    echo "hev-socks5-tunnel not found in PATH"
    exit 1
  }
  [[ -x "$HONEYGAIN_BIN" ]] || {
    echo "Honeygain binary not executable: $HONEYGAIN_BIN"
    exit 1
  }
  [[ -n "$HONEYGAIN_ACCOUNTS_RAW" ]] || {
    echo "HONEYGAIN_ACCOUNTS is empty. Configure accounts in main.sh first."
    exit 1
  }
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx - 1) / 254 + 1 ))
  local c=$(( (idx - 1) % 254 + 1 ))
  echo "$b" "$c"
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
    *)
      echo "UNSUPPORTED_PROTO"
      return 1
      ;;
  esac

  echo "$proto" "$user" "$pass" "$host" "$port"
}

check_proxy() {
  local proxy="$1"
  local curl_proxy="$proxy"

  if [[ "$curl_proxy" == socks5://* ]]; then
    curl_proxy="socks5h://${curl_proxy#socks5://}"
  fi

  curl -fsS \
    --proxy "$curl_proxy" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$TOTAL_TIMEOUT" \
    "http://1.1.1.1" >/dev/null
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
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$veth_ns"

  if [[ "$FORCE_NS_DNS" == "1" ]]; then
    mkdir -p "/etc/netns/$ns"
    : > "/etc/netns/$ns/resolv.conf"
    for dns_ip in $NS_DNS_LIST; do
      echo "nameserver $dns_ip" >> "/etc/netns/$ns/resolv.conf"
    done
  fi

  echo "$ns"
}

resolve_ipv4_targets() {
  local host="$1"

  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$host"
  else
    getent ahostsv4 "$host" | awk '{print $1}' | sort -u
  fi
}

pin_proxy_route_in_ns() {
  local ns="$1"
  local idx="$2"
  local proxy_host="$3"
  local b c gw dev ip

  read -r b c <<<"$(calc_octets "$idx")"
  gw="10.${b}.${c}.1"
  dev="${VETH_PREFIX}${idx}n"

  while read -r ip; do
    [[ -n "$ip" ]] || continue
    ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
  done < <(resolve_ipv4_targets "$proxy_host")
}

bypass_dns_via_veth() {
  local ns="$1"
  local idx="$2"
  local b c gw dev resolv ip

  read -r b c <<<"$(calc_octets "$idx")"
  gw="10.${b}.${c}.1"
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

configure_ns_egress_killswitch() {
  local ns="$1"
  local idx="$2"
  local proxy_host="$3"
  local b c ns_dev gateway ip

  read -r b c <<<"$(calc_octets "$idx")"
  ns_dev="${VETH_PREFIX}${idx}n"
  gateway="10.${b}.${c}.1"

  ip netns exec "$ns" iptables -F
  ip netns exec "$ns" iptables -P INPUT DROP
  ip netns exec "$ns" iptables -P OUTPUT DROP
  ip netns exec "$ns" iptables -P FORWARD DROP

  ip netns exec "$ns" iptables -A INPUT -i lo -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -o lo -j ACCEPT
  ip netns exec "$ns" iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip netns exec "$ns" iptables -A INPUT -i tun0 -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -o tun0 -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -o "$ns_dev" -d "$gateway" -j ACCEPT

  while read -r ip; do
    [[ -n "$ip" ]] || continue
    ip netns exec "$ns" iptables -A OUTPUT -o "$ns_dev" -d "$ip" -j ACCEPT
  done < <(resolve_ipv4_targets "$proxy_host")

  if [[ "$BYPASS_UDP53" == "1" || "$BYPASS_ALL_UDP" == "1" ]]; then
    for dns_ip in $NS_DNS_LIST; do
      ip netns exec "$ns" iptables -A OUTPUT -o "$ns_dev" -d "$dns_ip" -j ACCEPT
    done
  fi
}

configure_policy_routing() {
  local ns="$1"
  local idx="$2"
  local b c gw dev

  read -r b c <<<"$(calc_octets "$idx")"
  gw="10.${b}.${c}.1"
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
  (( ${#HONEYGAIN_ACCOUNTS_LIST[@]} > 0 )) || {
    echo "No Honeygain accounts supplied."
    exit 1
  }
}

start_instance() {
  local idx="$1"
  local proxy="$2"
  local email="$3"
  local password="$4"
  local device_no="$5"
  local parsed proto user pass host port ns b c
  local t_pidfile t_logfile t_cfgfile fwmark_dec tun_ip inst_dir mailname device_name

  parsed="$(parse_proxy "$proxy")" || {
    echo "[$idx] Bad proxy: $proxy"
    return 1
  }
  read -r proto user pass host port <<<"$parsed"

  ns="$(create_ns_with_veth "$idx")"
  read -r b c <<<"$(calc_octets "$idx")"
  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  t_pidfile="$WORKDIR/hev-socks5-tunnel_${idx}.pid"
  t_logfile="$WORKDIR/hev-socks5-tunnel_${idx}.log"
  t_cfgfile="$WORKDIR/hev-socks5-tunnel_${idx}.yml"
  fwmark_dec=$((FWMARK))
  tun_ip="198.18.${b}.${c}"

  if [[ "$proto" == "socks5h" ]]; then
    proto="socks5"
  fi
  if [[ "$proto" != "socks5" ]]; then
    echo "[$idx] Unsupported proxy protocol for Honeygain/hev-socks5-tunnel: $proto"
    return 1
  fi

  cat > "$t_cfgfile" <<CFG

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
  configure_ns_egress_killswitch "$ns" "$idx" "$host"

  inst_dir="$WORKDIR/inst_${idx}"
  mailname="${email%@*}"
  device_name="${mailname}-${device_no}"
  mkdir -p "$inst_dir"

  echo "[$idx] Starting Honeygain for $email as device $device_name via proxy=$proxy"
  ip netns exec "$ns" bash -c "cd '$(pwd)'; export HOME='$inst_dir'; export LD_LIBRARY_PATH='$HONEYGAIN_LIB_DIR:\${LD_LIBRARY_PATH:-}'; exec '$HONEYGAIN_BIN' -tou-accept -email '$email' -pass '$password' -device '$device_name'" \
    > "$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! > "$WORKDIR/app_${idx}.pid"
}

CLEANING_UP=0

stop_pidfiles() {
  local f pid
  for f in "$WORKDIR"/app_*.pid "$WORKDIR"/hev-socks5-tunnel_*.pid; do
    [[ -f "$f" ]] || continue
    pid="$(cat "$f")"
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for f in "$WORKDIR"/app_*.pid "$WORKDIR"/hev-socks5-tunnel_*.pid; do
    [[ -f "$f" ]] || continue
    pid="$(cat "$f")"
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local ns idx
  [[ "$CLEANING_UP" == "1" ]] && return
  CLEANING_UP=1

  echo
  echo "Cleaning up Honeygain..."
  stop_pidfiles
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    idx="${ns#${BASE_NS}}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

main() {
  local max_devices used account_index device_no entry email password proxy

  require_root
  setup_nat_once
  load_accounts

  [[ -f "$PROXY_FILE" ]] || {
    echo "Proxy file not found: $PROXY_FILE"
    exit 1
  }

  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  (( ${#proxies[@]} > 0 )) || {
    echo "No proxies in $PROXY_FILE"
    exit 1
  }

  echo "Loaded ${#proxies[@]} proxies from $PROXY_FILE"
  echo "Honeygain accounts available: ${#HONEYGAIN_ACCOUNTS_LIST[@]}"

  max_devices=$(( ${#HONEYGAIN_ACCOUNTS_LIST[@]} * DEVICES_PER_ACCOUNT ))
  if (( ${#proxies[@]} > max_devices )); then
    echo "Only $max_devices proxies can be used because each Honeygain account is limited to $DEVICES_PER_ACCOUNT devices. Extra proxies will be skipped."
  fi

  used=0
  for proxy in "${proxies[@]}"; do
    if (( used >= max_devices )); then
      break
    fi

    if [[ "$CHECK_WORKING" == "1" ]] && ! check_proxy "$proxy"; then
      echo "[src] dead: $proxy"
      continue
    fi

    account_index=$(( used / DEVICES_PER_ACCOUNT ))
    device_no=$(( used % DEVICES_PER_ACCOUNT + 1 ))
    entry="${HONEYGAIN_ACCOUNTS_LIST[$account_index]}"
    email="${entry%%|*}"
    password="${entry#*|}"
    used=$((used + 1))

    start_instance "$used" "$proxy" "$email" "$password" "$device_no"
  done

  (( used > 0 )) || {
    echo "No usable proxies after filtering."
    exit 1
  }

  echo
  echo "Started $used Honeygain instance(s). Logs:"
  echo "  $WORKDIR/app_*.log"
  echo "  $WORKDIR/hev-socks5-tunnel_*.log"
  echo "Ctrl+C to stop and cleanup."
  wait
}

main "$@"
