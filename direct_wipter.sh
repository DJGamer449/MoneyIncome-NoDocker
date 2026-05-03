#!/usr/bin/env bash
set -euo pipefail

PROXY_FILE="${1:-proxies.txt}"
CHECK_WORKING="${CHECK_WORKING:-1}"
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
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-0}"
WIPTER_SCRIPT="${WIPTER_SCRIPT:-./wipter.sh}"
WIPTER_EMAIL="${WIPTER_EMAIL:-${EMAIL:-}}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-${PASSWORD:-}}"

mkdir -p "$WORKDIR"

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root. Example: sudo $0 $PROXY_FILE"; exit 1; }
  command -v hev-socks5-tunnel >/dev/null 2>&1 || { echo "hev-socks5-tunnel not found in PATH"; exit 1; }
  [[ -x "$WIPTER_SCRIPT" ]] || { echo "wipter launcher not executable: $WIPTER_SCRIPT"; exit 1; }
  [[ -n "$WIPTER_EMAIL" && -n "$WIPTER_PASSWORD" ]] || { echo "WIPTER_EMAIL/WIPTER_PASSWORD required"; exit 1; }
}

calc_octets() { local i="$1"; echo $(( (i-1)/254 + 1 )) $(( (i-1)%254 + 1 )); }
parse_proxy() {
  local l="$1" p r c h u pw host port
  p="${l%%://*}"; r="${l#*://}"; c="${r%@*}"; h="${r#*@}"
  u="${c%%:*}"; pw="${c#*:}"; host="${h%%:*}"; port="${h#*:}"
  case "$p" in socks5|socks5h|http|https) ;; *) return 1;; esac
  echo "$p" "$u" "$pw" "$host" "$port"
}

check_proxy() {
  local p="$1"; [[ "$p" == socks5://* ]] && p="socks5h://${p#socks5://}"
  curl -fsS --proxy "$p" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" http://1.1.1.1 >/dev/null
}

setup_nat_once(){
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

create_ns_with_veth(){
  local i="$1" ns="${BASE_NS}${i}" vh="${VETH_PREFIX}${i}h" vn="${VETH_PREFIX}${i}n" b c
  read -r b c <<<"$(calc_octets "$i")"
  ip netns add "$ns" 2>/dev/null || true
  ip link show "$vh" >/dev/null 2>&1 || ip link add "$vh" type veth peer name "$vn"
  ip link set "$vn" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$vh" 2>/dev/null || true
  ip link set "$vh" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$vn" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$vn" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$vn"
  if [[ "$FORCE_NS_DNS" == "1" ]]; then
    mkdir -p "/etc/netns/$ns"; : > "/etc/netns/$ns/resolv.conf"
    for d in $NS_DNS_LIST; do echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"; done
  fi
  echo "$ns"
}

pin_proxy_route_in_ns(){
  local ns="$1" i="$2" host="$3" b c gw dev ip
  read -r b c <<<"$(calc_octets "$i")"; gw="10.${b}.${c}.1"; dev="${VETH_PREFIX}${i}n"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip netns exec "$ns" ip route replace "$host/32" via "$gw" dev "$dev" || true
  else
    while read -r ip; do ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true; done < <(getent ahostsv4 "$host" | awk '{print $1}' | sort -u)
  fi
}

configure_policy_routing(){
  local ns="$1" i="$2" b c gw dev
  read -r b c <<<"$(calc_octets "$i")"; gw="10.${b}.${c}.1"; dev="${VETH_PREFIX}${i}n"
  ip netns exec "$ns" ip route replace default via "$gw" dev "$dev" 2>/dev/null || true
  ip netns exec "$ns" ip route flush table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip route add default dev tun0 table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip rule add fwmark "$FWMARK" lookup main priority 100 2>/dev/null || true
  if [[ "$BYPASS_ALL_UDP" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp lookup main priority 101 2>/dev/null || true
  elif [[ "$BYPASS_UDP53" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp dport 53 lookup main priority 101 2>/dev/null || true
  fi
  ip netns exec "$ns" ip rule add lookup "$TUN_TABLE" priority 200 2>/dev/null || true
}

start_instance(){
  local i="$1" proxy="$2" parsed proto user pass host port ns b c
  parsed="$(parse_proxy "$proxy")" || { echo "[$i] Bad proxy: $proxy"; return; }
  read -r proto user pass host port <<<"$parsed"
  ns="$(create_ns_with_veth "$i")"
  read -r b c <<<"$(calc_octets "$i")"
  pin_proxy_route_in_ns "$ns" "$i" "$host"

  local cfg="$WORKDIR/hev_${i}.yml" pidf="$WORKDIR/hev_${i}.pid" logf="$WORKDIR/hev_${i}.log"
  local wdir="$WORKDIR/instance_${i}" wlog="$wdir/wipter-run.log" seedlog="$wdir/wipter-seed-launch.log"
  mkdir -p "$wdir"

  cat > "$cfg" <<CFG
main:
  workers: 1
  port: 0
  log-level: info
misc:
  task-stack-size: 32768
  tcp-buffer-size: 4096
  connect-timeout: 10
tunnel:
  name: tun0
  mtu: 8500
  ipv4: 198.18.${b}.${c}
  ipv6: 'fc00::${i}'
  mapdns: true
socks5:
  port: $port
  address: '$host'
  udp: 'udp'
  pipeline: true
  username: '$user'
  password: '$pass'
  # only socks5/auth are used even for http(s) lines; keep compatibility with existing setup
  # for http proxy endpoints, use a socks capable endpoint.
  tcp:
    no-delay: true
    keep-alive: true
    fast-open: false
  udp:
    fake-dns: false
    udp-in-tcp: false
  connect-timeout: 10
  read-write-timeout: 300
  handshake-timeout: 10
transport:
  fwmark: $((FWMARK))
CFG

  ip netns exec "$ns" sh -c "nohup hev-socks5-tunnel -c '$cfg' >'$logf' 2>&1 & echo \$! > '$pidf'"
  sleep 1
  configure_policy_routing "$ns" "$i"

  echo "[$i] Starting Wipter in $ns (logs: $wlog ; app log symlink /tmp/wipter-run.log inside ns)."
  ip netns exec "$ns" env HOME="$wdir" XDG_CONFIG_HOME="$wdir/.config" XDG_DATA_HOME="$wdir/.local/share" \
    WIPTER_EMAIL="$WIPTER_EMAIL" WIPTER_PASSWORD="$WIPTER_PASSWORD" EMAIL="$WIPTER_EMAIL" PASSWORD="$WIPTER_PASSWORD" \
    WIPTER_LOG="$seedlog" FINAL_WIPTER_LOG="$wlog" \
    bash -lc "ln -sf '$wlog' /tmp/wipter-run.log; nohup '$WIPTER_SCRIPT' >'$wdir/direct_wipter.out' 2>&1 & echo \\$! > '$wdir/wipter.pid'"
}

main(){
  require_root; setup_nat_once
  [[ -f "$PROXY_FILE" ]] || { echo "Proxy file not found: $PROXY_FILE"; exit 1; }
  local i=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [[ -z "$line" ]] && continue
    i=$((i+1))
    if [[ "$CHECK_WORKING" == "1" ]] && ! check_proxy "$line"; then echo "[$i] Skip dead proxy"; continue; fi
    start_instance "$i" "$line"
  done < "$PROXY_FILE"
  echo "Done. Instance data/logs are under: $WORKDIR/instance_*"
}

main "$@"
