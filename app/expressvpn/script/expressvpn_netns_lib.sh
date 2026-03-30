#!/usr/bin/env bash
set -euo pipefail

EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$(pwd)/app/expressvpn/bin}"
EXPRESSVPN_SERVICE_SRC="${EXPRESSVPN_SERVICE_SRC:-$(pwd)/app/expressvpn/expressvpn-service}"
EXPRESSVPN_SCRIPT_DIR="${EXPRESSVPN_SCRIPT_DIR:-$(pwd)/app/expressvpn/script}"
EXPRESSVPN_INST_ROOT="${EXPRESSVPN_INST_ROOT:-/opt/expressvpn}"
WORKDIR="${WORKDIR:-/tmp/expressvpn_multi}"
BASE_NS="${BASE_NS:-vpnns}"
VETH_PREFIX="${VETH_PREFIX:-vpn}"
HOST_IF="${HOST_IF:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}') }"
APP_NAME="${APP_NAME:-app}"
APP_CMD="${APP_CMD:-echo missing APP_CMD}"
APP_ENV_EXPORTS="${APP_ENV_EXPORTS:-}"
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
EXPRESSVPN_ACTIVATION_KEY="${EXPRESSVPN_ACTIVATION_KEY:-}"
REGIONS_RAW="${REGIONS_RAW:-}"

mkdir -p "$WORKDIR"

calc_octets() {
  local idx="$1"
  local b=$(( (idx - 1) / 254 + 1 ))
  local c=$(( (idx - 1) % 254 + 1 ))
  echo "$b" "$c"
}

require_root_and_files() {
  [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
  [[ -n "$HOST_IF" ]] || HOST_IF="eth0"
  [[ -n "$EXPRESSVPN_ACTIVATION_KEY" ]] || { echo "EXPRESSVPN_ACTIVATION_KEY is required"; exit 1; }
  [[ -d "$EXPRESSVPN_BIN_DIR" ]] || { echo "Missing $EXPRESSVPN_BIN_DIR"; exit 1; }
  [[ -f "$EXPRESSVPN_SERVICE_SRC" ]] || { echo "Missing $EXPRESSVPN_SERVICE_SRC"; exit 1; }
  [[ -n "$REGIONS_RAW" ]] || { echo "REGIONS_RAW is required"; exit 1; }
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

create_ns_with_veth() {
  local idx="$1" ns="${BASE_NS}${idx}" vh="${VETH_PREFIX}${idx}h" vn="${VETH_PREFIX}${idx}n" b c
  read -r b c <<<"$(calc_octets "$idx")"
  ip netns add "$ns" 2>/dev/null || true
  ip link show "$vh" >/dev/null 2>&1 || ip link add "$vh" type veth peer name "$vn"
  ip link set "$vn" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$vh" 2>/dev/null || true
  ip link set "$vh" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$vn" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$vn" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$vn"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  echo "$ns"
}

region_for_index() {
  local idx="$1"
  mapfile -t regions < <(printf '%s\n' "$REGIONS_RAW" | sed '/^\s*$/d')
  local total=${#regions[@]}
  local pick=$(( (idx - 1) % total ))
  echo "${regions[$pick]}"
}

prepare_instance_files() {
  local idx="$1" inst="$EXPRESSVPN_INST_ROOT/instance-$idx"
  mkdir -p "$inst/bin" "$inst/etc/init.d" "$inst/var" "$inst/tmp" "$inst/run"
  cp -a "$EXPRESSVPN_BIN_DIR/." "$inst/bin/"
  cp -f "$EXPRESSVPN_SERVICE_SRC" "$inst/etc/init.d/expressvpn-service"
  chmod +x "$inst/etc/init.d/expressvpn-service" "$inst/bin"/* 2>/dev/null || true
  echo "$inst"
}

start_expressvpn_in_ns() {
  local ns="$1" idx="$2" region="$3" inst="$4"
  local daemon="$inst/bin/expressvpn"
  local log="$WORKDIR/expressvpn_${idx}.log"

  ip netns exec "$ns" unshare -m bash -lc "
    mount --make-rprivate / || true
    mkdir -p /opt/expressvpn /etc/init.d /expressvpn
    mount --bind '$inst' /opt/expressvpn
    mount --bind '$EXPRESSVPN_SCRIPT_DIR' /expressvpn
    cp -f /opt/expressvpn/etc/init.d/expressvpn-service /etc/init.d/expressvpn-service
    chmod +x /etc/init.d/expressvpn-service
    export PATH=/opt/expressvpn/bin:\$PATH
    export EXPRESSVPN_CONFIG_DIR=/opt/expressvpn/var
    export EXPRESSVPN_LOG_DIR=/opt/expressvpn/var
    export TMPDIR=/opt/expressvpn/tmp
    nohup /opt/expressvpn/bin/expressvpn-agent > '$log' 2>&1 &
    sleep 2
    /opt/expressvpn/bin/expressvpn activate '$EXPRESSVPN_ACTIVATION_KEY' || true
    /opt/expressvpn/bin/expressvpn preferences set network_lock true || true
    /opt/expressvpn/bin/expressvpn connect '$region'
  "

  ip netns exec "$ns" bash -c 'for i in {1..80}; do ip link show tun0 >/dev/null 2>&1 && exit 0; sleep 0.25; done; exit 1' || {
    echo "[$idx] tun0 not ready"
    return 1
  }

  ip netns exec "$ns" iptables -F
  ip netns exec "$ns" iptables -P INPUT DROP
  ip netns exec "$ns" iptables -P OUTPUT DROP
  ip netns exec "$ns" iptables -P FORWARD DROP
  ip netns exec "$ns" iptables -A INPUT -i lo -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -o lo -j ACCEPT
  ip netns exec "$ns" iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip netns exec "$ns" iptables -A OUTPUT -o tun0 -j ACCEPT
  ip netns exec "$ns" iptables -A INPUT -i tun0 -j ACCEPT

  local pubip
  pubip="$(ip netns exec "$ns" curl -4fsS --max-time 20 https://api.ipify.org || echo unknown)"
  echo "[$idx] Connected region=$region public_ip=$pubip ns=$ns"
}

run_app_in_ns() {
  local ns="$1" idx="$2" inst="$3"
  local app_log="$WORKDIR/${APP_NAME}_${idx}.log"
  ip netns exec "$ns" unshare -m bash -lc "
    mount --make-rprivate / || true
    mountpoint -q /opt/expressvpn || { mkdir -p /opt/expressvpn; mount --bind '$inst' /opt/expressvpn; }
    mountpoint -q /expressvpn || { mkdir -p /expressvpn; mount --bind '$EXPRESSVPN_SCRIPT_DIR' /expressvpn; }
    export PATH=/opt/expressvpn/bin:\$PATH
    export EXPRESSVPN_CONFIG_DIR=/opt/expressvpn/var
    export EXPRESSVPN_LOG_DIR=/opt/expressvpn/var
    export HOME='$WORKDIR/home_${APP_NAME}_${idx}'
    mkdir -p \"\$HOME\"
    $APP_ENV_EXPORTS
    nohup bash -lc '$APP_CMD' > '$app_log' 2>&1 &
    echo \$! > '$WORKDIR/${APP_NAME}_${idx}.pid'
  "
}

run_app_instances() {
  require_root_and_files
  setup_nat_once
  local i ns region inst
  for ((i=1;i<=INSTANCE_COUNT;i++)); do
    ns="$(create_ns_with_veth "$i")"
    region="$(region_for_index "$i")"
    inst="$(prepare_instance_files "$i")"
    start_expressvpn_in_ns "$ns" "$i" "$region" "$inst"
    run_app_in_ns "$ns" "$i" "$inst"
  done
  echo "Started $INSTANCE_COUNT isolated $APP_NAME instance(s)."
  wait
}
