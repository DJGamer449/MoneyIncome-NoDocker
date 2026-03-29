#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-app}"
APP_CMD="${APP_CMD:-true}"
BASE_NS="${BASE_NS:-vpnns}"
VETH_PREFIX="${VETH_PREFIX:-vpnv}"
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
EXPRESSVPN_ACTIVATION_CODE="${EXPRESSVPN_ACTIVATION_CODE:-}"
REGIONS_CSV="${REGIONS_CSV:-}"
WORKDIR="${WORKDIR:-/tmp/${APP_NAME}_expressvpn}"

mkdir -p "$WORKDIR"

prompt_if_missing_inputs() {
  if [[ -z "${EXPRESSVPN_ACTIVATION_CODE}" ]]; then
    read -rp "ExpressVPN activation code: " EXPRESSVPN_ACTIVATION_CODE
  fi

  if [[ -z "${INSTANCE_COUNT}" || ! "${INSTANCE_COUNT}" =~ ^[0-9]+$ ]]; then
    read -rp "Instance count: " INSTANCE_COUNT
  fi

  if [[ -z "${REGIONS_CSV}" ]]; then
    local i region regions=()
    for ((i=1; i<=INSTANCE_COUNT; i++)); do
      read -rp "Region for instance ${i}: " region
      regions+=("$region")
    done
    IFS=',' REGIONS_CSV="${regions[*]}"
  fi
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
  [[ -d "./app/expressvpn" ]] || { echo "Missing ./app/expressvpn"; exit 1; }
  [[ -d "./app/expressvpn/bin" ]] || { echo "Missing ./app/expressvpn/bin"; exit 1; }
  [[ -d "./app/expressvpn/script" ]] || { echo "Missing ./app/expressvpn/script"; exit 1; }
  [[ -n "$EXPRESSVPN_ACTIVATION_CODE" ]] || { echo "EXPRESSVPN_ACTIVATION_CODE is empty"; exit 1; }
  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "INSTANCE_COUNT must be integer"; exit 1; }
}

host_if() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx-1)/254 + 1 ))
  local c=$(( (idx-1)%254 + 1 ))
  echo "$b" "$c"
}

setup_ns() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local veth_h="${VETH_PREFIX}${idx}h"
  local veth_n="${VETH_PREFIX}${idx}n"
  local b c
  read -r b c <<<"$(calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true
  ip link show "$veth_h" >/dev/null 2>&1 || ip link add "$veth_h" type veth peer name "$veth_n"
  ip link set "$veth_n" netns "$ns" 2>/dev/null || true

  ip addr add "10.${b}.${c}.1/24" dev "$veth_h" 2>/dev/null || true
  ip link set "$veth_h" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$veth_n" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_n" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$veth_n"

  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"

  local iface
  iface="$(host_if)"
  iface="${iface:-eth0}"
  iptables -t nat -C POSTROUTING -s "10.${b}.${c}.0/24" -o "$iface" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "10.${b}.${c}.0/24" -o "$iface" -j MASQUERADE
}

prepare_expressvpn_instance() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local inst_dir="/opt/expressvpn/${ns}"

  mkdir -p "$inst_dir" "/etc/netns/$ns/init.d"
  cp -a ./app/expressvpn/. "$inst_dir/"

  # Keep per-instance init service copy.
  if [[ -f "$inst_dir/expressvpn-service" ]]; then
    mkdir -p "$inst_dir/etc/init.d"
    install -m 0755 "$inst_dir/expressvpn-service" "$inst_dir/etc/init.d/expressvpn-service"
    install -m 0755 "$inst_dir/expressvpn-service" "/etc/netns/$ns/init.d/expressvpn-service"
  fi

  # Put binaries in default command path as requested.
  if [[ -d "$inst_dir/bin" ]]; then
    find "$inst_dir/bin" -maxdepth 1 -type f -exec install -m 0755 {} /usr/bin/ \;
  fi
}

connect_expressvpn() {
  local idx="$1"
  local region="$2"
  local ns="${BASE_NS}${idx}"
  local inst_dir="/opt/expressvpn/${ns}"
  local log_file="$WORKDIR/expressvpn_${idx}.log"

  ip netns exec "$ns" bash -lc "
    set -e
    mkdir -p /expressvpn
    mountpoint -q /expressvpn || mount --bind '$inst_dir/script' /expressvpn
    chmod +x /expressvpn/start.sh
    export PATH='$inst_dir/bin':\$PATH
    export HOME='$inst_dir'
    export CODE='$EXPRESSVPN_ACTIVATION_CODE'
    export SERVER='$region'
    /expressvpn/start.sh
  " >>"$log_file" 2>&1
}

start_app_instance() {
  local idx="$1"
  local region="$2"
  local ns="${BASE_NS}${idx}"
  local inst_home="$WORKDIR/${APP_NAME}_${idx}"
  local app_log="$WORKDIR/${APP_NAME}_${idx}.log"
  local pid_file="$WORKDIR/${APP_NAME}_${idx}.pid"

  mkdir -p "$inst_home"

  ip netns exec "$ns" bash -lc "
    export HOME='$inst_home'
    cd '$(pwd)'
    nohup bash -lc '$APP_CMD' >'$app_log' 2>&1 &
    echo \$! > '$pid_file'
  "

  local ip_check
  ip_check="$(ip netns exec "$ns" bash -lc "curl -fsS --max-time 15 ifconfig.me || true")"
  echo "[$APP_NAME-$idx] netns=$ns region=$region ip=${ip_check:-unknown}"
}

main() {
  prompt_if_missing_inputs
  require_root
  mapfile -t REGIONS < <(tr ',' '\n' <<<"$REGIONS_CSV" | sed 's/^ *//;s/ *$//' | sed '/^$/d') || true
  (( ${#REGIONS[@]} > 0 )) || { echo "No regions supplied via REGIONS_CSV"; exit 1; }

  local i ri region
  echo "Starting ${APP_NAME} with ${INSTANCE_COUNT} isolated netns instances..."
  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    ri=$(( (i-1) % ${#REGIONS[@]} ))
    region="${REGIONS[$ri]}"
    setup_ns "$i"
    prepare_expressvpn_instance "$i"
    connect_expressvpn "$i" "$region"
    start_app_instance "$i" "$region"
  done

  echo "$APP_NAME started with $INSTANCE_COUNT isolated expressvpn namespaces. Logs: $WORKDIR"
  wait
}

main "$@"
