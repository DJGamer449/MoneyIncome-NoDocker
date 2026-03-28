#!/usr/bin/env bash
set -euo pipefail

INSTANCE_COUNT="${1:-1}"
APP_NAME="${APP_NAME:-app}"
BASE_NS="${BASE_NS:-appns}"
VETH_PREFIX="${VETH_PREFIX:-app}"
WORKDIR="${WORKDIR:-/tmp/${APP_NAME}_multi}"
SERVER="${SERVER:-smart}"
PROTOCOL="${PROTOCOL:-lightwayudp}"
APP_LAUNCH_CMD="${APP_LAUNCH_CMD:-echo missing APP_LAUNCH_CMD; exit 1}"

mkdir -p "$WORKDIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL_DEFAULT="${SCRIPT_DIR}/app/expressvpn/bin/expressvpnctl"
if [[ -x "$CTL_DEFAULT" ]]; then
  CTL="$CTL_DEFAULT"
else
  CTL="$(command -v expressvpnctl || true)"
fi

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 <instance_count>"; exit 1; }
  [[ -n "$CTL" ]] || { echo "expressvpnctl not found (expected at ./app/expressvpn/bin/expressvpnctl or PATH)"; exit 1; }
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx-1) / 254 + 1 ))
  local c=$(( (idx-1) % 254 + 1 ))
  echo "$b" "$c"
}

create_ns_with_veth() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local host_if="${VETH_PREFIX}${idx}h"
  local ns_if="${VETH_PREFIX}${idx}n"
  local b c
  read -r b c <<<"$(calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true
  ip link show "$host_if" >/dev/null 2>&1 || ip link add "$host_if" type veth peer name "$ns_if"
  ip link set "$ns_if" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$ns_if"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  echo "$ns"
}

activate_and_connect_expressvpn() {
  if [[ -z "${CODE:-}" ]]; then
    read -r -s -p "Enter ExpressVPN activation key (CODE): " CODE
    echo
  fi
  [[ -n "${CODE:-}" ]] || { echo "CODE is required"; exit 1; }

  local code_file
  code_file="$(mktemp)"
  printf '%s' "$CODE" >"$code_file"

  "$CTL" --timeout 60 login "$code_file" >/tmp/${APP_NAME}_xvpn_login.log 2>&1 || true
  rm -f "$code_file"

  "$CTL" set protocol "$PROTOCOL" >/dev/null 2>&1 || true
  "$CTL" disconnect >/dev/null 2>&1 || true
  "$CTL" connect "$SERVER"

  for _ in {1..45}; do
    [[ "$("$CTL" get connectionstate 2>/dev/null || true)" == "Connected" ]] && return 0
    sleep 2
  done
  echo "ExpressVPN failed to reach Connected state (server=$SERVER)"
  exit 1
}

start_instance() {
  local idx="$1"
  local ns
  ns="$(create_ns_with_veth "$idx")"
  local inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"

  local cmd="${APP_LAUNCH_CMD//\{INDEX\}/$idx}"
  cmd="${cmd//\{WORKDIR\}/$WORKDIR}"
  cmd="${cmd//\{INSTANCE_DIR\}/$inst_dir}"

  echo "[$idx] Starting $APP_NAME via ExpressVPN($SERVER)"
  ip netns exec "$ns" env HOME="$inst_dir" PATH="$PATH" INDEX="$idx" INSTANCE_DIR="$inst_dir" WORKDIR="$WORKDIR" \
    bash -lc "cd '$SCRIPT_DIR'; exec $cmd" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#$BASE_NS}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}

main() {
  require_root
  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "INSTANCE_COUNT must be an integer"; exit 1; }
  (( INSTANCE_COUNT > 0 )) || { echo "INSTANCE_COUNT must be > 0"; exit 1; }

  setup_nat_once
  activate_and_connect_expressvpn

  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    start_instance "$i"
  done

  echo "Started $INSTANCE_COUNT instance(s) of $APP_NAME. Logs in $WORKDIR"
  echo "Press Ctrl+C to stop."
  wait
}

trap cleanup EXIT
main "$@"
