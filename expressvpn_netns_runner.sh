#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION_FILE="${REGION_FILE:-$BASE_DIR/expressvpn_region.txt}"
APP_NAME="${APP_NAME:?APP_NAME is required}"
APP_CMD="${APP_CMD:?APP_CMD is required}"
INSTANCE_COUNT="${INSTANCE_COUNT:?INSTANCE_COUNT is required}"
EXPRESSVPN_CODE="${EXPRESSVPN_CODE:?EXPRESSVPN_CODE is required}"
BASE_NS="${BASE_NS:-${APP_NAME}ns}"
VETH_PREFIX="${VETH_PREFIX:-${APP_NAME}v}"
WORKDIR="${WORKDIR:-/tmp/${APP_NAME}_runtime}"
mkdir -p "$WORKDIR"

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
  command -v ip >/dev/null 2>&1 || { echo "ip command missing"; exit 1; }
  command -v service >/dev/null 2>&1 || { echo "service command missing"; exit 1; }
}

load_regions() {
  [[ -f "$REGION_FILE" ]] || { echo "Region file missing: $REGION_FILE"; exit 1; }
  mapfile -t REGIONS < <(tr '\n' ' ' < "$REGION_FILE" | tr -d "'" | xargs -n1)
  (( ${#REGIONS[@]} > 0 )) || { echo "No regions loaded"; exit 1; }
}

region_for_instance() {
  local idx="$1"
  local total="${#REGIONS[@]}"
  local pos=$(( (idx - 1) % total ))
  echo "${REGIONS[$pos]}"
}

create_netns() {
  local idx="$1" ns="$2" host_if="$3" ns_if="$4" subnet_gw="$5" subnet_ns="$6" subnet_cidr="$7"
  ip netns add "$ns" 2>/dev/null || true
  ip link show "$host_if" >/dev/null 2>&1 || ip link add "$host_if" type veth peer name "$ns_if"
  ip link set "$ns_if" netns "$ns"
  ip addr add "$subnet_gw" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr add "$subnet_ns" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route replace default via "${subnet_gw%/*}" dev "$ns_if"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  iptables -t nat -C POSTROUTING -s "$subnet_cidr" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$subnet_cidr" -j MASQUERADE
}

prepare_instance_tree() {
  local idx="$1" inst_root="/opt/expressvpn/${APP_NAME}-${idx}"
  rm -rf "$inst_root"
  mkdir -p "$inst_root"
  cp -a "$BASE_DIR/app/expressvpn/bin" "$inst_root/"
  cp -a "$BASE_DIR/app/expressvpn/lib" "$inst_root/"
  cp -a "$BASE_DIR/app/expressvpn/etc" "$inst_root/"
  cp -a "$BASE_DIR/app/expressvpn/plugins" "$inst_root/" 2>/dev/null || true
  cp -a "$BASE_DIR/app/expressvpn/qml" "$inst_root/" 2>/dev/null || true
  cp -a "$BASE_DIR/app/expressvpn/share" "$inst_root/" 2>/dev/null || true
  cp -a "$BASE_DIR/app/expressvpn/var" "$inst_root/" 2>/dev/null || true
  cp "$BASE_DIR/app/expressvpn/expressvpn-service" "$inst_root/expressvpn-service"
  chmod +x "$inst_root/expressvpn-service"
  echo "$inst_root"
}

start_instance() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local host_if="${VETH_PREFIX}${idx}h"
  local ns_if="${VETH_PREFIX}${idx}n"
  local b=$(( (idx-1)/254 + 1 ))
  local c=$(( (idx-1)%254 + 1 ))
  local subnet_gw="10.${b}.${c}.1/24"
  local subnet_ns="10.${b}.${c}.2/24"
  local subnet_cidr="10.${b}.${c}.0/24"
  local region
  region="$(region_for_instance "$idx")"
  local inst_root
  inst_root="$(prepare_instance_tree "$idx")"
  local runtime_script="/tmp/${APP_NAME}_runtime_${idx}.sh"

  create_netns "$idx" "$ns" "$host_if" "$ns_if" "$subnet_gw" "$subnet_ns" "$subnet_cidr"

  cat > "$runtime_script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
mount --make-rprivate / || true
mkdir -p /opt/expressvpn /expressvpn /etc/init.d /tmp/expressvpn /expressvpn/www
mount --bind "$inst_root" /opt/expressvpn
mount --bind "$BASE_DIR/app/expressvpn/script" /expressvpn
cp /opt/expressvpn/expressvpn-service /etc/init.d/expressvpn-service
chmod 755 /etc/init.d/expressvpn-service
export PATH="/opt/expressvpn/bin:\$PATH"
export LD_LIBRARY_PATH="/opt/expressvpn/lib"
export CODE="$EXPRESSVPN_CODE"
export SERVER="$region"
export PROTOCOL="lightwayudp"
export ALLOW_LAN="true"
mkdir -p /tmp/expressvpn
bash /expressvpn/start.sh
exec bash -lc "$APP_CMD"
SCRIPT
  chmod +x "$runtime_script"

  ip netns exec "$ns" unshare -m --propagation private bash "$runtime_script" >"$WORKDIR/${APP_NAME}_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/${APP_NAME}_${idx}.pid"
  echo "[$idx] ${APP_NAME} started in $ns region=$region log=$WORKDIR/${APP_NAME}_${idx}.log"
}

cleanup() {
  local idx ns host_if b c subnet_cidr
  for idx in $(seq 1 "$INSTANCE_COUNT"); do
    ns="${BASE_NS}${idx}"
    host_if="${VETH_PREFIX}${idx}h"
    b=$(( (idx-1)/254 + 1 ))
    c=$(( (idx-1)%254 + 1 ))
    subnet_cidr="10.${b}.${c}.0/24"
    [[ -f "$WORKDIR/${APP_NAME}_${idx}.pid" ]] && kill "$(cat "$WORKDIR/${APP_NAME}_${idx}.pid")" 2>/dev/null || true
    ip netns delete "$ns" 2>/dev/null || true
    ip link delete "$host_if" 2>/dev/null || true
    rm -rf "/etc/netns/$ns"
    iptables -t nat -D POSTROUTING -s "$subnet_cidr" -j MASQUERADE 2>/dev/null || true
  done
}

trap cleanup INT TERM
require_root
load_regions
for i in $(seq 1 "$INSTANCE_COUNT"); do
  start_instance "$i"
done
wait
