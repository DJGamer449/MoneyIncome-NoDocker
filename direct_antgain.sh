#!/usr/bin/env bash
set -euo pipefail

# ===============================
# ANTGAIN DIRECT MULTI INSTANCE
# ===============================

PROXY_FILE="${1:-proxies.txt}"

# If main.sh injected the key, use it.
# Otherwise ask user once.
if [[ -z "${ANTGAIN_API_KEY:-}" ]]; then
  read -rp "Enter ANTGAIN API KEY: " ANTGAIN_API_KEY
fi

APP_CMD=( ./antgain )

CHECK_WORKING="${CHECK_WORKING:-1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"

BASE_NS="${BASE_NS:-antns}"
VETH_PREFIX="${VETH_PREFIX:-ant}"
WORKDIR="${WORKDIR:-/tmp/antgain_multi}"
mkdir -p "$WORKDIR"

FWMARK="${FWMARK:-0x22b}"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
  command -v tun2socks >/dev/null || {
    echo "tun2socks not installed"
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
  local proto rest hostport host port

  proto="${line%%://*}"
  rest="${line#*://}"
  hostport="${rest#*@}"

  host="${hostport%%:*}"
  port="${hostport#*:}"

  echo "$proto" "$host" "$port"
}

check_proxy() {
  local proxy="$1"

  curl -fsS \
    --proxy "$proxy" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$TOTAL_TIMEOUT" \
    http://1.1.1.1 >/dev/null
}

create_ns() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local veth_host="${VETH_PREFIX}${idx}h"
  local veth_ns="${VETH_PREFIX}${idx}n"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true

  ip link add "$veth_host" type veth peer name "$veth_ns" 2>/dev/null || true
  ip link set "$veth_ns" netns "$ns"

  ip addr add "10.${B}.${C}.1/24" dev "$veth_host" 2>/dev/null || true
  ip link set "$veth_host" up

  ip netns exec "$ns" ip addr add "10.${B}.${C}.2/24" dev "$veth_ns" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_ns" up

  ip netns exec "$ns" ip route replace default via "10.${B}.${C}.1"

  echo "$ns"
}

start_instance() {
  local idx="$1"
  local proxy="$2"

  local ns
  ns="$(create_ns "$idx")"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  ip netns exec "$ns" ip tuntap add dev tun0 mode tun
  ip netns exec "$ns" ip addr add "198.18.${B}.${C}/30" dev tun0
  ip netns exec "$ns" ip link set tun0 up

  local t_pidfile="$WORKDIR/tun2socks_${idx}.pid"

  ip netns exec "$ns" bash -c "
    tun2socks -device tun0 -proxy '$proxy' -fwmark '$FWMARK' &
    echo \$! > '$t_pidfile'
  "

  echo "[$idx] Starting AntGain..."

  ip netns exec "$ns" bash -c "
    export ANTGAIN_API_KEY='$ANTGAIN_API_KEY'
    cd '$(pwd)'
    ${APP_CMD[*]}
  " > "$WORKDIR/antgain_${idx}.log" 2>&1 &

  echo $! > "$WORKDIR/app_${idx}.pid"
}

cleanup() {
  echo "Stopping AntGain..."

  for f in "$WORKDIR"/app_*.pid; do
    [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true
  done

  for f in "$WORKDIR"/tun2socks_*.pid; do
    [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true
  done
}

trap cleanup EXIT

main() {
  require_root

  [[ -f "$PROXY_FILE" ]] || {
    echo "Proxy file missing: $PROXY_FILE"
    exit 1
  }

  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE")

  echo "Loaded ${#proxies[@]} proxies"

  used=0
  for p in "${proxies[@]}"; do
    if [[ "$CHECK_WORKING" == "1" ]]; then
      if ! check_proxy "$p"; then
        echo "Proxy dead: $p"
        continue
      fi
    fi

    used=$((used+1))
    start_instance "$used" "$p"
  done

  echo "Started $used AntGain instances"
  wait
}

main "$@"