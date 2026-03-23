#!/usr/bin/env bash
set -euo pipefail

PROXY_FILE="${1:-proxies.txt}"
CHECK_WORKING="${CHECK_WORKING:-1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
BASE_NS="${BASE_NS:-mystns}"
VETH_PREFIX="${VETH_PREFIX:-mystv}"
WORKDIR="${WORKDIR:-/tmp/mysterium_multi}"
FWMARK="${FWMARK:-0x22b}"
TUN_TABLE="${TUN_TABLE:-100}"
BYPASS_UDP53="${BYPASS_UDP53:-0}"
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-0}"
AUTO_UDP_DIRECT_FALLBACK="${AUTO_UDP_DIRECT_FALLBACK:-1}"
MYST_BIN="${MYST_BIN:-$(command -v myst 2>/dev/null || true)}"
MYST_BASE_DIR="${MYST_BASE_DIR:-$(pwd)/myst}"
MYST_UI_BASE_PORT="${MYST_UI_BASE_PORT:-4449}"
MYST_TERMS_FLAG="${MYST_TERMS_FLAG:---agreed-terms-and-conditions}"
MYST_EXTRA_ARGS="${MYST_EXTRA_ARGS:-}"
SOCAT_BIN="${SOCAT_BIN:-$(command -v socat 2>/dev/null || true)}"

mkdir -p "$WORKDIR" "$MYST_BASE_DIR"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 $PROXY_FILE"
    exit 1
  fi

  [[ -n "$MYST_BIN" && -x "$MYST_BIN" ]] || {
    echo "myst binary not found. Install it first with ./install_mysterium_node.sh"
    exit 1
  }
  command -v hev-socks5-tunnel >/dev/null 2>&1 || {
    echo "hev-socks5-tunnel not found in PATH"
    exit 1
  }
  [[ -n "$SOCAT_BIN" && -x "$SOCAT_BIN" ]] || {
    echo "socat not found. Install dependencies first."
    exit 1
  }
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx - 1) / 254 + 1 ))
  local c=$(( (idx - 1) % 254 + 1 ))
  echo "$b" "$c"
}

instance_dir() {
  local idx="$1"
  echo "$MYST_BASE_DIR/myst-$idx"
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
    socks5|socks5h) ;;
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

enable_udp_direct_bypass() {
  local ns="$1"

  ip netns exec "$ns" ip rule del ipproto udp dport 53 lookup main priority 101 2>/dev/null || true
  ip netns exec "$ns" ip rule del iif lo ipproto udp dport 53 lookup main priority 102 2>/dev/null || true
  ip netns exec "$ns" ip rule add ipproto udp lookup main priority 101 2>/dev/null || true
}

udp_probe_works() {
  local ns="$1"

  ip netns exec "$ns" python3 - <<'PY'
import socket
import sys

targets = [
    ("1.1.1.1", 53, b"\xaa\xaa\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x01a\x01a\x00\x00\x01\x00\x01"),
    ("8.8.8.8", 53, b"\xbb\xbb\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x01a\x01a\x00\x00\x01\x00\x01"),
]

for host, port, payload in targets:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(3.0)
    try:
        sock.sendto(payload, (host, port))
        data, _ = sock.recvfrom(512)
        if data:
            sys.exit(0)
    except OSError:
        pass
    finally:
        sock.close()

sys.exit(1)
PY
}

apply_udp_fallback_if_needed() {
  local ns="$1"
  local idx="$2"

  [[ "$AUTO_UDP_DIRECT_FALLBACK" == "1" ]] || return 0
  [[ "$BYPASS_ALL_UDP" == "0" ]] || return 0

  if udp_probe_works "$ns"; then
    echo "[$idx] UDP relay over tunnel is working."
    return 0
  fi

  echo "[$idx] UDP relay over tunnel failed; enabling direct UDP fallback in namespace."
  enable_udp_direct_bypass "$ns"
}

start_host_forwarder() {
  local idx="$1"
  local ns="$2"
  local listen_port=$((MYST_UI_BASE_PORT + idx))
  local pidfile="$WORKDIR/forward_${idx}.pid"
  local logfile="$WORKDIR/forward_${idx}.log"

  "$SOCAT_BIN" \
    "TCP-LISTEN:${listen_port},bind=127.0.0.1,reuseaddr,fork" \
    "EXEC:ip netns exec ${ns} ${SOCAT_BIN} STDIO TCP\\:127.0.0.1\\:${MYST_UI_BASE_PORT},nofork" \
    >"$logfile" 2>&1 &
  echo $! >"$pidfile"
  echo "[$idx] Connect UI forwarded to http://127.0.0.1:${listen_port}"
}

start_instance() {
  local idx="$1"
  local proxy="$2"
  local parsed proto user pass host port ns b c

  parsed="$(parse_proxy "$proxy")" || { echo "[$idx] Bad proxy: $proxy"; return 1; }
  read -r proto user pass host port <<<"$parsed"

  ns="$(create_ns_with_veth "$idx")"
  read -r b c <<<"$(calc_octets "$idx")"
  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  local t_pidfile="$WORKDIR/hev_${idx}.pid"
  local t_logfile="$WORKDIR/hev_${idx}.log"
  local t_cfgfile="$WORKDIR/hev_${idx}.yml"
  local fwmark_dec=$((FWMARK))
  local tun_ip="198.18.${b}.${c}"

  [[ "$proto" == "socks5h" ]] && proto="socks5"

  cat >"$t_cfgfile" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  ipv4: $tun_ip
socks5:
  address: $host
  port: $port
  udp: 'tcp'
  username: '$user'
  password: '$pass'
  mark: $fwmark_dec
misc:
  log-file: stderr
  log-level: info
EOF

  ip netns exec "$ns" bash -c "
    hev-socks5-tunnel '$t_cfgfile' >'$t_logfile' 2>&1 &
    echo \$! > '$t_pidfile'
  "

  ip netns exec "$ns" bash -c 'for i in {1..50}; do ip link show tun0 >/dev/null 2>&1 && exit 0; sleep 0.1; done; exit 1' || {
    echo "[$idx] tun0 was not created by hev-socks5-tunnel"
    return 1
  }

  configure_policy_routing "$ns" "$idx"
  bypass_dns_via_veth "$ns" "$idx"
  reset_ns_firewall_allow_all "$ns"
  apply_udp_fallback_if_needed "$ns" "$idx"

  local root_dir data_dir config_dir runtime_dir log_dir app_pidfile app_logfile ui_port
  root_dir="$(instance_dir "$idx")"
  data_dir="$root_dir/data"
  config_dir="$root_dir/config"
  runtime_dir="$root_dir/run"
  log_dir="$root_dir/logs"
  app_pidfile="$WORKDIR/myst_${idx}.pid"
  app_logfile="$log_dir/myst.log"
  ui_port=$((MYST_UI_BASE_PORT + idx))

  mkdir -p "$data_dir" "$config_dir" "$runtime_dir" "$log_dir"

  start_host_forwarder "$idx" "$ns"

  echo "[$idx] Starting Mysterium node in $root_dir"
  ip netns exec "$ns" bash -lc "
    export HOME='$root_dir'
    cd '$(pwd)'
    exec '$MYST_BIN' \
      --data-dir='$data_dir' \
      --config-dir='$config_dir' \
      --runtime-dir='$runtime_dir' \
      service $MYST_TERMS_FLAG $MYST_EXTRA_ARGS
  " >"$app_logfile" 2>&1 &
  echo $! >"$app_pidfile"
  echo "[$idx] Reused/persisted data dir: $data_dir"
  echo "[$idx] Host UI port: http://127.0.0.1:${ui_port}"
}

cleanup() {
  echo
  echo "Cleaning up Mysterium namespaces..."
  for f in "$WORKDIR"/myst_*.pid "$WORKDIR"/hev_*.pid "$WORKDIR"/forward_*.pid; do
    [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true
  done

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

  [[ -f "$PROXY_FILE" ]] || { echo "Proxy file not found: $PROXY_FILE"; exit 1; }

  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  (( ${#proxies[@]} > 0 )) || { echo "No proxies in $PROXY_FILE"; exit 1; }

  echo "Loaded ${#proxies[@]} proxies from $PROXY_FILE"
  echo "Using persistent base dir: $MYST_BASE_DIR"
  echo "UI base port inside namespace: $MYST_UI_BASE_PORT"
  echo "AUTO_UDP_DIRECT_FALLBACK=$AUTO_UDP_DIRECT_FALLBACK"

  local used=0
  local source_idx=0
  for proxy in "${proxies[@]}"; do
    source_idx=$((source_idx + 1))

    if [[ "$CHECK_WORKING" == "1" ]]; then
      if ! check_proxy "$proxy"; then
        echo "[src#$source_idx] dead: $proxy"
        continue
      fi
      echo "[src#$source_idx] ok: $proxy"
    fi

    used=$((used + 1))
    start_instance "$used" "$proxy"
  done

  (( used > 0 )) || { echo "No usable proxies after filtering."; exit 1; }

  echo
  echo "Started $used Mysterium node instance(s)."
  echo "Persistent instance dirs:"
  echo "  $MYST_BASE_DIR/myst-*"
  echo "Logs:"
  echo "  $WORKDIR/hev_*.log"
  echo "  $MYST_BASE_DIR/myst-*/logs/myst.log"
  echo "Ctrl+C to stop and cleanup namespaces. Instance data directories are preserved."
  wait
}

main "$@"
