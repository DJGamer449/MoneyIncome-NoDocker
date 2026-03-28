#!/usr/bin/env bash
set -euo pipefail

# Run multiple EarnApp instances in net namespaces while host traffic is already on ExpressVPN.
# No hev-socks5-tunnel/proxy routing is used.

INSTANCE_COUNT="${1:-1}"
BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earn}"
WORKDIR="${WORKDIR:-/tmp/earnapp_clones}"
SERVER="${SERVER:-smart}"
PROTOCOL="${PROTOCOL:-lightwayudp}"
mkdir -p "$WORKDIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL_DEFAULT="${SCRIPT_DIR}/app/expressvpn/bin/expressvpnctl"
if [[ -x "$CTL_DEFAULT" ]]; then
  CTL="$CTL_DEFAULT"
else
  CTL="$(command -v expressvpnctl || true)"
fi

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 <instance_count>"
    exit 1
  fi
  [[ -n "$CTL" ]] || { echo "expressvpnctl not found (expected at ./app/expressvpn/bin/expressvpnctl or PATH)"; exit 1; }
  command -v earnapp >/dev/null 2>&1 || { echo "earnapp not found in PATH (/usr/bin/earnapp)"; exit 1; }
}

calc_octets() {
  local idx="$1"
  local B=$(( (idx-1) / 254 + 1 ))
  local C=$(( (idx-1) % 254 + 1 ))
  echo "$B" "$C"
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

  "$CTL" --timeout 60 login "$code_file" >/tmp/earnapp_xvpn_login.log 2>&1 || true
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

start_app_instance() {
  local idx="$1"
  local ns
  ns="$(create_ns_with_veth "$idx")"

  local inst_dir="$WORKDIR/inst_${idx}"
  local etc_dir="$inst_dir/etc"
  mkdir -p "$etc_dir"

  local uuid_file="$inst_dir/uuid.txt"
  if [[ ! -f "$uuid_file" ]]; then
    local raw_uuid
    raw_uuid="$(uuidgen | tr -d '-')"
    printf '%s' "sdk-node-${raw_uuid:0:32}" >"$uuid_file"
  fi
  local earnapp_uuid
  earnapp_uuid="$(cat "$uuid_file")"

  printf '%s' "$earnapp_uuid" >"$etc_dir/uuid"
  touch "$etc_dir/status"
  chmod a+wr "$etc_dir" "$etc_dir/status" "$etc_dir/uuid"

  echo "[$idx] Starting EarnApp UUID: https://earnapp.com/r/$earnapp_uuid via ExpressVPN($SERVER)"

  ip netns exec "$ns" unshare -m bash -c "
    mount --make-rprivate / 2>/dev/null || true
    mkdir -p /etc/earnapp
    mount --bind '$etc_dir' /etc/earnapp

    /usr/bin/earnapp start &
    sleep 5
    exec /usr/bin/earnapp run
  " >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  echo
  echo "Cleaning up..."
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#$BASE_NS}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}

collect_ids() {
  local used_count="$1"
  local output_file="earnapp.txt"
  echo "Waiting for EarnApp instances to initialize IDs (15s)..."
  sleep 15

  : >"$output_file"
  for (( idx=1; idx<=used_count; idx++ )); do
    local ns="${BASE_NS}${idx}"
    local inst_dir="$WORKDIR/inst_${idx}"
    local etc_dir="$inst_dir/etc"

    local earnapp_id
    earnapp_id="$(ip netns exec "$ns" unshare -m bash -c "
      mount --bind '$etc_dir' /etc/earnapp
      /usr/bin/earnapp showid 2>/dev/null | grep -o 'sdk-node-[a-z0-9]\+' || true
    ")"

    if [[ -n "$earnapp_id" ]]; then
      local line="earnapp-$idx: https://earnapp.com/r/$earnapp_id"
      echo "$line"
      echo "$line" >>"$output_file"
    else
      echo "earnapp-$idx: Failed to retrieve ID (check $WORKDIR/app_$idx.log)"
    fi
  done
  echo "All IDs saved to $(readlink -f "$output_file")"
}

main() {
  require_root
  setup_nat_once
  activate_and_connect_expressvpn

  if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || (( INSTANCE_COUNT < 1 )); then
    echo "INSTANCE_COUNT must be a positive integer (received: $INSTANCE_COUNT)"
    exit 1
  fi

  echo "Launching ${INSTANCE_COUNT} EarnApp instance(s) through ExpressVPN server=${SERVER}"
  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    start_app_instance "$i"
  done

  collect_ids "$INSTANCE_COUNT"
  echo "Processes are running. Logs are in $WORKDIR"
  echo "Press Ctrl+C to stop all instances."
  wait
}

trap cleanup EXIT
main "$@"
