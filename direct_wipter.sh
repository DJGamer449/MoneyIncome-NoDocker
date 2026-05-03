#!/usr/bin/env bash
set -euo pipefail

PROXY_FILE="${1:-proxies.txt}"

CHECK_WORKING="${CHECK_WORKING:-1}"
CHECK_SPEED="${CHECK_SPEED:-0}"
MAX_LAT_MS="${MAX_LAT_MS:-1500}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"

FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_multi}"

FWMARK="${FWMARK:-0x22b}"
TUN_TABLE="${TUN_TABLE:-100}"
BYPASS_UDP53="${BYPASS_UDP53:-1}"
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-1}"

WIPTER_EMAIL="${WIPTER_EMAIL:-${EMAIL:-}}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-${PASSWORD:-}}"

mkdir -p "$WORKDIR"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 $PROXY_FILE"
    exit 1
  fi

  command -v tun2socks >/dev/null 2>&1 || { echo "tun2socks not found in PATH"; exit 1; }
  command -v wipter-app >/dev/null 2>&1 || { echo "wipter-app not found in PATH"; exit 1; }
  [[ -x "./wipter.sh" ]] || { echo "wipter.sh not found or not executable in current directory"; exit 1; }

  if [[ -z "$WIPTER_EMAIL" || -z "$WIPTER_PASSWORD" ]]; then
    echo "Missing credentials. Set WIPTER_EMAIL and WIPTER_PASSWORD (or EMAIL/PASSWORD)."
    exit 1
  fi
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx-1) / 254 + 1 ))
  local c=$(( (idx-1) % 254 + 1 ))
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
    *) echo "UNSUPPORTED_PROTO"; return 1 ;;
  esac

  echo "$proto" "$user" "$pass" "$host" "$port"
}

check_proxy() {
  local proxy="$1"
  local p="$proxy"
  local start end elapsed

  if [[ "$p" == socks5://* ]]; then
    p="socks5h://${p#socks5://}"
  fi

  start="$(date +%s%3N)"
  if ! curl -fsS --proxy "$p" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" http://1.1.1.1 >/dev/null; then
    echo "FAIL"
    return 1
  fi
  end="$(date +%s%3N)"
  elapsed=$(( end - start ))

  if [[ "$CHECK_SPEED" == "1" ]] && (( elapsed > MAX_LAT_MS )); then
    echo "SLOW ${elapsed}ms"
    return 2
  fi

  echo "OK ${elapsed}ms"
  return 0
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
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
    for dns in $NS_DNS_LIST; do
      echo "nameserver $dns" >> "/etc/netns/$ns/resolv.conf"
    done
  fi

  echo "$ns"
}

pin_proxy_route_in_ns() {
  local ns="$1"
  local idx="$2"
  local proxy_host="$3"
  local b c

  read -r b c <<<"$(calc_octets "$idx")"

  local gw="10.${b}.${c}.1"
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

configure_policy_routing() {
  local ns="$1"
  local idx="$2"
  local b c

  read -r b c <<<"$(calc_octets "$idx")"

  local gw="10.${b}.${c}.1"
  local dev="${VETH_PREFIX}${idx}n"

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

start_instance() {
  local idx="$1"
  local proxy="$2"
  local parsed proto user pass host port

  parsed="$(parse_proxy "$proxy")" || {
    echo "[$idx] Bad proxy: $proxy"
    return 1
  }
  read -r proto user pass host port <<<"$parsed"

  local ns
  ns="$(create_ns_with_veth "$idx")"

  local b c
  read -r b c <<<"$(calc_octets "$idx")"

  ip netns exec "$ns" ip tuntap add dev tun0 mode tun 2>/dev/null || true
  ip netns exec "$ns" ip addr add "198.18.${b}.${c}/30" dev tun0 2>/dev/null || true
  ip netns exec "$ns" ip link set tun0 up

  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  local tun_log="$WORKDIR/tun2socks_${idx}.log"
  local tun_pid="$WORKDIR/tun2socks_${idx}.pid"

  ip netns exec "$ns" bash -lc "
    tun2socks -device tun0 -proxy '$proxy' -fwmark '$FWMARK' > '$tun_log' 2>&1 &
    echo \$! > '$tun_pid'
  "

  configure_policy_routing "$ns" "$idx"

  local inst_dir="$WORKDIR/inst_${idx}"
  local home_dir="$inst_dir/home"
  local xdg_runtime_dir="$inst_dir/xdg-runtime"
  mkdir -p "$home_dir" "$xdg_runtime_dir"
  chmod 700 "$xdg_runtime_dir"

  local bootstrap_log="$WORKDIR/wipter-bootstrap-${idx}.log"
  local seed_log="$WORKDIR/wipter-seed-${idx}.log"
  local app_log="$WORKDIR/wipter-run-${idx}.log"

  ip netns exec "$ns" env \
    HOME="$home_dir" \
    XDG_RUNTIME_DIR="$xdg_runtime_dir" \
    EMAIL="$WIPTER_EMAIL" \
    PASSWORD="$WIPTER_PASSWORD" \
    WIPTER_LOG="$seed_log" \
    FINAL_WIPTER_LOG="$app_log" \
    bash ./wipter.sh > "$bootstrap_log" 2>&1 &

  echo "[$idx] Wipter started in namespace: $ns"
  echo "[$idx] Logs:"
  echo "  bootstrap: $bootstrap_log"
  echo "  seed:      $seed_log"
  echo "  run:       $app_log"
  echo "  legacy default inside wipter.sh if not overridden: /tmp/wipter-run.log"
}

main() {
  require_root

  if [[ ! -f "$PROXY_FILE" ]]; then
    echo "Proxy file not found: $PROXY_FILE"
    exit 1
  fi

  setup_nat_once

  local idx=0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[$'\t\r\n ']/}"
    [[ -z "$line" ]] && continue

    idx=$((idx + 1))
    if [[ "$CHECK_WORKING" == "1" ]]; then
      if ! check_proxy "$line" >/dev/null; then
        echo "[$idx] Proxy failed check, skipping"
        continue
      fi
    fi

    start_instance "$idx" "$line" || true
    sleep 0.2
  done < "$PROXY_FILE"

  echo "Spawn complete. Processed proxies: $idx"
  wait
}

main "$@"
