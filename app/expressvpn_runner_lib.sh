#!/usr/bin/env bash
set -euo pipefail

xvpn_resolve_ctl() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local embedded="${root}/app/expressvpn/bin/expressvpnctl"
  if [[ -x "$embedded" ]]; then
    printf '%s\n' "$embedded"
    return 0
  fi
  command -v expressvpnctl
}

xvpn_require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root."
    exit 1
  fi
}

xvpn_setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

xvpn_calc_octets() {
  local idx="$1"
  local b=$(( (idx-1) / 254 + 1 ))
  local c=$(( (idx-1) % 254 + 1 ))
  echo "$b" "$c"
}

xvpn_create_ns() {
  local idx="$1"
  local base_ns="$2"
  local veth_prefix="$3"
  local ns="${base_ns}${idx}"
  local veth_host="${veth_prefix}${idx}h"
  local veth_ns="${veth_prefix}${idx}n"
  local b c
  read -r b c <<<"$(xvpn_calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true
  ip link show "$veth_host" >/dev/null 2>&1 || ip link add "$veth_host" type veth peer name "$veth_ns"
  ip link set "$veth_ns" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$veth_host" 2>/dev/null || true
  ip link set "$veth_host" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$veth_ns" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$veth_ns"

  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  printf '%s\n' "$ns"
}

xvpn_cleanup_ns() {
  local base_ns="$1"
  local veth_prefix="$2"
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${base_ns}[0-9]+$" || true); do
    local idx="${ns#$base_ns}"
    ip link del "${veth_prefix}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}

xvpn_activate_and_connect() {
  local ctl="$1"
  local server="${2:-smart}"
  local protocol="${3:-lightwayudp}"

  if [[ -z "${CODE:-}" ]]; then
    read -r -s -p "Enter ExpressVPN activation key (CODE): " CODE
    echo
  fi
  [[ -n "${CODE:-}" ]] || { echo "CODE is required"; exit 1; }

  local code_file
  code_file="$(mktemp)"
  printf '%s' "$CODE" >"$code_file"
  "$ctl" --timeout 60 login "$code_file" >/tmp/xvpn-login.log 2>&1 || true
  rm -f "$code_file"

  "$ctl" set protocol "$protocol" >/dev/null 2>&1 || true
  "$ctl" disconnect >/dev/null 2>&1 || true
  "$ctl" connect "$server"

  for _ in {1..60}; do
    [[ "$("$ctl" get connectionstate 2>/dev/null || true)" == "Connected" ]] && return 0
    sleep 2
  done
  echo "ExpressVPN failed to connect to ${server}"
  exit 1
}
