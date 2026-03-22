#!/usr/bin/env bash
set -euo pipefail

PROXY_FILE="${1:-proxies.txt}"
HONEYGAIN_APP_DIR="${HONEYGAIN_APP_DIR:-./app/honeygain_file}"
HONEYGAIN_BIN_NAME="${HONEYGAIN_BIN_NAME:-honeygain}"
HONEYGAIN_BIN="${HONEYGAIN_BIN:-./app/honeygain_file/honeygain}"
HONEYGAIN_ACCOUNTS_FILE="${HONEYGAIN_ACCOUNTS_FILE:-./honeygain_password.txt}"
CHECK_WORKING="${CHECK_WORKING:-1}"
CHECK_SPEED="${CHECK_SPEED:-0}"
MAX_LAT_MS="${MAX_LAT_MS:-1500}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
FWMARK="${FWMARK:-0x22b}"
TUN_TABLE="${TUN_TABLE:-100}"
BYPASS_UDP53="${BYPASS_UDP53:-0}"
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-0}"
BYPASS_UDP53="${BYPASS_UDP53:-1}"
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-1}"
DEVICES_PER_ACCOUNT=10
mkdir -p "$WORKDIR"

declare -a HONEYGAIN_ACCOUNTS=()

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 $PROXY_FILE"
    exit 1
  fi
  command -v tun2socks >/dev/null 2>&1 || { echo "tun2socks not found in PATH"; exit 1; }
  [[ -d "$HONEYGAIN_APP_DIR" ]] || { echo "Honeygain app directory not found: $HONEYGAIN_APP_DIR"; exit 1; }
  [[ -x "$HONEYGAIN_APP_DIR/$HONEYGAIN_BIN_NAME" ]] || { echo "Honeygain binary not executable: $HONEYGAIN_APP_DIR/$HONEYGAIN_BIN_NAME"; exit 1; }
  [[ -x "$HONEYGAIN_BIN" ]] || { echo "Honeygain binary not executable: $HONEYGAIN_BIN"; exit 1; }
  [[ -f "$HONEYGAIN_ACCOUNTS_FILE" ]] || { echo "Honeygain account file not found: $HONEYGAIN_ACCOUNTS_FILE"; exit 1; }
}

load_honeygain_accounts() {
  while IFS='|' read -r email password; do
    [[ -n "${email:-}" && -n "${password:-}" ]] || continue
    HONEYGAIN_ACCOUNTS+=("$email|$password")
  done < "$HONEYGAIN_ACCOUNTS_FILE"

  (( ${#HONEYGAIN_ACCOUNTS[@]} > 0 )) || {
    echo "No Honeygain accounts configured in $HONEYGAIN_ACCOUNTS_FILE"
    exit 1
  }
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
  local start end ms
  local p="$proxy"
  if [[ "$p" == socks5://* ]]; then
    p="socks5h://${p#socks5://}"
  fi

  start="$(date +%s%3N)"
  if ! curl -fsS --proxy "$p" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" "http://1.1.1.1" >/dev/null; then
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

email_mailname() {
  local email="$1"
  local localpart="${email%@*}"
  local sanitized
  sanitized="$(printf '%s' "$localpart" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')"
  printf '%s' "${sanitized:-device}"
}

prepare_honeygain_instance() {
  local idx="$1"
  local __inst_dir_var="$2"
  local __app_dir_var="$3"
  local inst_dir="$WORKDIR/inst_${idx}"
  local app_dir="$WORKDIR/app_${idx}"

  rm -rf "$app_dir"
  mkdir -p "$inst_dir"
  cp -a "$HONEYGAIN_APP_DIR/." "$app_dir/"
  chmod +x "$app_dir/$HONEYGAIN_BIN_NAME"

  printf -v "$__inst_dir_var" '%s' "$inst_dir"
  printf -v "$__app_dir_var" '%s' "$app_dir"
}

start_tun2socks_and_honeygain() {
  local idx="$1"
  local proxy="$2"
  local email="$3"
  local password="$4"
  local device_num="$5"

  local parsed proto user pass host port
  parsed="$(parse_proxy "$proxy")" || { echo "[$idx] Bad proxy: $proxy"; return 1; }
  read -r proto user pass host port <<<"$parsed"

  local ns
  ns="$(create_ns_with_veth "$idx")"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  ip netns exec "$ns" ip tuntap add dev tun0 mode tun
  ip netns exec "$ns" ip addr add "198.18.${B}.${C}/30" dev tun0
  ip netns exec "$ns" ip link set tun0 up

  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  local t_pidfile="$WORKDIR/tun2socks_${idx}.pid"
  local t_logfile="$WORKDIR/tun2socks_${idx}.log"
  ip netns exec "$ns" bash -c "
    tun2socks -device tun0 -proxy '$proxy' -fwmark '$FWMARK' >'$t_logfile' 2>&1 &
    echo \$! > '$t_pidfile'
  "

  configure_policy_routing "$ns" "$idx"
  bypass_dns_via_veth "$ns" "$idx"
  reset_ns_firewall_allow_all "$ns"

  local inst_dir app_dir
  prepare_honeygain_instance "$idx" inst_dir app_dir

  local inst_dir="$WORKDIR/inst_${idx}"
  local mailname
  mailname="$(email_mailname "$email")"
  local device_name="${mailname}-${device_num}"
  local app_logfile="$WORKDIR/honeygain_${idx}.log"

  echo "[$idx] Starting Honeygain for $email as device=$device_name via proxy=$proxy (netns=$ns)"
  ip netns exec "$ns" bash -c "cd '$app_dir'; export HOME='$inst_dir'; './$HONEYGAIN_BIN_NAME' -tou-accept -email '$email' -pass '$password' -device '$device_name'" \
  mkdir -p "$inst_dir"

  echo "[$idx] Starting Honeygain for $email as device=$device_name via proxy=$proxy (netns=$ns)"
  ip netns exec "$ns" bash -c "cd '$(pwd)'; export HOME='$inst_dir'; '$HONEYGAIN_BIN' -tou-accept -email '$email' -pass '$password' -device '$device_name'" \
    >"$app_logfile" 2>&1 &

  echo $! >"$WORKDIR/honeygain_${idx}.pid"
}

cleanup() {
  echo
  echo "Cleaning up Honeygain namespaces..."
  for f in "$WORKDIR"/honeygain_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for f in "$WORKDIR"/tun2socks_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
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
  load_honeygain_accounts
  setup_nat_once
  [[ -f "$PROXY_FILE" ]] || { echo "Proxy file not found: $PROXY_FILE"; exit 1; }

  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  (( ${#proxies[@]} > 0 )) || { echo "No proxies in $PROXY_FILE"; exit 1; }

  local max_devices=$(( ${#HONEYGAIN_ACCOUNTS[@]} * DEVICES_PER_ACCOUNT ))
  echo "Loaded ${#proxies[@]} proxies from $PROXY_FILE"
  echo "Loaded ${#HONEYGAIN_ACCOUNTS[@]} Honeygain account(s); capacity=${max_devices} devices"
  echo "UDP bypass disabled for Honeygain so traffic stays inside tun2socks unless you override BYPASS_ALL_UDP/BYPASS_UDP53."

  local used=0
  local i=0
  local proxy res account_idx device_num email password account_entry
  for proxy in "${proxies[@]}"; do
    i=$((i+1))

    if (( used >= max_devices )); then
      echo "Reached Honeygain capacity (${max_devices} devices across ${#HONEYGAIN_ACCOUNTS[@]} account(s)). Remaining proxies are skipped."
      break
    fi

    if [[ "$CHECK_WORKING" == "1" ]]; then
      res="$(check_proxy "$proxy" || true)"
      if [[ "$res" == FAIL* ]]; then
        echo "[src#$i] dead: $proxy"
        continue
      fi
      if [[ "$res" == SLOW* ]]; then
        echo "[src#$i] too slow ($res): $proxy"
        continue
      fi
      echo "[src#$i] ok ($res): $proxy"
    fi

    used=$((used+1))
    account_idx=$(( (used - 1) / DEVICES_PER_ACCOUNT ))
    device_num=$(( (used - 1) % DEVICES_PER_ACCOUNT + 1 ))
    account_entry="${HONEYGAIN_ACCOUNTS[$account_idx]}"
    email="${account_entry%%|*}"
    password="${account_entry#*|}"

    start_tun2socks_and_honeygain "$used" "$proxy" "$email" "$password" "$device_num"
  done

  (( used > 0 )) || { echo "No usable proxies after filtering."; exit 1; }

  echo
  echo "Started $used Honeygain device(s). Logs:"
  echo "  $WORKDIR/honeygain_*.log"
  echo "  $WORKDIR/tun2socks_*.log"
  echo "Ctrl+C to stop and cleanup."
  wait
}

main "$@"
