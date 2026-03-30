#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION_FILE="${REGION_FILE:-$BASE_DIR/expressvpn_region.txt}"
EXPRESSVPN_SRC="${EXPRESSVPN_SRC:-$BASE_DIR/app/expressvpn}"
EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$EXPRESSVPN_SRC/bin}"
EXPRESSVPN_SCRIPT_DIR="${EXPRESSVPN_SCRIPT_DIR:-$BASE_DIR/app/expressvpn/script}"
SERVICE_TEMPLATE="${SERVICE_TEMPLATE:-$BASE_DIR/app/expressvpn/expressvpn-service}"
WORKDIR="${WORKDIR:-/tmp/expressvpn_multi}"
BASE_NS="${BASE_NS:-vpnns}"
VETH_PREFIX="${VETH_PREFIX:-vpnv}"
APP_NAME="${APP_NAME:-app}"
APP_CMD="${APP_CMD:-echo missing APP_CMD; sleep infinity}"

mkdir -p "$WORKDIR"

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
  [[ -d "$EXPRESSVPN_BIN_DIR" ]] || { echo "Missing expressvpn bin dir: $EXPRESSVPN_BIN_DIR"; exit 1; }
  [[ -f "$SERVICE_TEMPLATE" ]] || { echo "Missing service template: $SERVICE_TEMPLATE"; exit 1; }
}

load_regions() {
  mapfile -t REGIONS < <(python3 - "$REGION_FILE" <<'PY'
import shlex,sys
p=sys.argv[1]
with open(p,'r',encoding='utf-8') as f:
    txt=f.read()
for tok in shlex.split(txt):
    t=tok.strip()
    if t:
        print(t)
PY
)
  [[ ${#REGIONS[@]} -gt 0 ]] || { echo "No regions found in $REGION_FILE"; exit 1; }
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx-1) / 254 + 1 ))
  local c=$(( (idx-1) % 254 + 1 ))
  echo "$b" "$c"
}

create_ns() {
  local idx="$1" ns="${BASE_NS}${idx}" host_if="${VETH_PREFIX}${idx}h" ns_if="${VETH_PREFIX}${idx}n"
  local b c; read -r b c <<<"$(calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true
  if ! ip link show "$host_if" >/dev/null 2>&1; then
    ip link add "$host_if" type veth peer name "$ns_if"
  fi
  ip link set "$ns_if" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$ns_if"

  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s "10.${b}.${c}.0/24" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "10.${b}.${c}.0/24" -j MASQUERADE

  echo "$ns"
}

prepare_instance_files() {
  local ns="$1" idx="$2"
  local inst_root="$WORKDIR/$ns"
  local inst_opt="/opt/expressvpn/$ns"
  mkdir -p "$inst_root/etc/init.d" "$inst_root/tmp" "$inst_opt"

  rsync -a --delete "$EXPRESSVPN_SRC/" "$inst_opt/"
  cp "$SERVICE_TEMPLATE" "$inst_root/etc/init.d/expressvpn-service"
  chmod +x "$inst_root/etc/init.d/expressvpn-service"

  echo "$inst_root|$inst_opt"
}

start_instance() {
  local idx="$1" region="$2" ns="$3" activation_key="$4"
  local app_cmd_inst="$5"
  local prep inst_root inst_opt
  prep="$(prepare_instance_files "$ns" "$idx")"
  inst_root="${prep%%|*}"
  inst_opt="${prep##*|}"

  local log_file="$WORKDIR/${APP_NAME}_${idx}.log"
  local pid_file="$WORKDIR/${APP_NAME}_${idx}.pid"

  echo "[$idx] netns=$ns region=$region"
  INSTANCE_INDEX="$idx" INSTANCE_NS="$ns" INSTANCE_REGION="$region" INSTANCE_KEY="$activation_key" \
  INSTANCE_OPT="$inst_opt" INSTANCE_ROOT="$inst_root" INSTANCE_APP_CMD="$app_cmd_inst" \
  INSTANCE_LOG="$log_file" INSTANCE_PID="$pid_file" SCRIPT_DIR="$EXPRESSVPN_SCRIPT_DIR" \
  ip netns exec "$ns" unshare -m bash -lc '
    set -euo pipefail
    mount --make-rprivate /
    mkdir -p /opt/expressvpn /expressvpn /etc/init.d
    mount --bind "$INSTANCE_OPT" /opt/expressvpn
    mount --bind "$SCRIPT_DIR" /expressvpn
    mount --bind "$INSTANCE_ROOT/etc/init.d/expressvpn-service" /etc/init.d/expressvpn-service

    export PATH="/opt/expressvpn/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/expressvpn/lib:${LD_LIBRARY_PATH:-}"
    export EXPRESSVPN_RUNTIME_BASE="/tmp/expressvpn/${INSTANCE_NS}"
    mkdir -p "$EXPRESSVPN_RUNTIME_BASE"

    service expressvpn-service stop >/dev/null 2>&1 || true
    service expressvpn-service start >/dev/null

    code_file="$(mktemp)"
    printf "%s" "$INSTANCE_KEY" > "$code_file"
    if ! expressvpnctl --timeout 60 login "$code_file" >/tmp/evpn-login.log 2>&1; then
      if ! grep -qi "Already logged into account" /tmp/evpn-login.log; then
        cat /tmp/evpn-login.log
        rm -f "$code_file"
        exit 1
      fi
    fi
    rm -f "$code_file"

    expressvpnctl disconnect >/dev/null 2>&1 || true
    expressvpnctl connect "$INSTANCE_REGION"

    for _ in $(seq 1 60); do
      state="$(expressvpnctl get connectionstate 2>/dev/null || true)"
      [[ "$state" == "Connected" ]] && ip link show tun0 >/dev/null 2>&1 && break
      sleep 1
    done

    pubip="$(expressvpnctl get pubip 2>/dev/null || true)"
    vpnip="$(expressvpnctl get vpnip 2>/dev/null || true)"
    echo "[$INSTANCE_INDEX] Connected pubip=${pubip} vpnip=${vpnip} region=${INSTANCE_REGION}" >> "$INSTANCE_LOG"

    bash -lc "$INSTANCE_APP_CMD" >> "$INSTANCE_LOG" 2>&1 &
    echo $! > "$INSTANCE_PID"
    wait $(cat "$INSTANCE_PID")
  ' &
}

main() {
  require_root
  load_regions

  read -rsp "Enter ExpressVPN activation key: " ACTIVATION_KEY
  echo
  [[ -n "$ACTIVATION_KEY" ]] || { echo "Activation key is required."; exit 1; }

  read -rp "How many ${APP_NAME} instances do you want to run? " INSTANCE_COUNT
  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "Invalid instance count"; exit 1; }
  (( INSTANCE_COUNT > 0 )) || { echo "Instance count must be > 0"; exit 1; }

  local i ns region
  for i in $(seq 1 "$INSTANCE_COUNT"); do
    region="${REGIONS[$(( (i-1) % ${#REGIONS[@]} ))]}"
    ns="$(create_ns "$i")"
    start_instance "$i" "$region" "$ns" "$ACTIVATION_KEY" "$APP_CMD"
  done

  wait
}

main "$@"
