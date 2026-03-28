#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earn}"
WORKDIR="${WORKDIR:-/tmp/earnapp_expressvpn}"
EXPRESSVPNCTL="${EXPRESSVPNCTL:-$(pwd)/app/expressvpn/bin/expressvpnctl}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
mkdir -p "$WORKDIR"

REGIONS=(
usa-san-francisco usa-new-jersey-2 usa-lincoln-park usa-houston usa-tampa-1 usa-new-jersey-3 usa-brooklyn usa-denver
usa-dallas usa-atlanta usa-seattle usa-miami-2 usa-salt-lake-city usa-santa-monica usa-washington-dc usa-new-jersey-1
usa-boston usa-birmingham usa-anchorage usa-little-rock usa-bridgeport usa-wilmington usa-honolulu usa-boise
usa-indianapolis usa-des-moines usa-wichita usa-louisville usa-new-orleans usa-portland-maine usa-baltimore usa-detroit
usa-minneapolis usa-jackson usa-st.-louis usa-billings usa-omaha usa-las-vegas usa-manchester usa-charlotte
usa-fargo usa-columbus usa-oklahoma-city usa-portland-oregon usa-philadelphia usa-providence
usa-charleston-south-carolina usa-sioux-falls usa-nashville usa-burlington usa-virginia-beach
usa-charleston-west-virginia usa-milwaukee usa-cheyenne usa-miami usa-los-angeles-1 usa-los-angeles-2
usa-los-angeles-5 usa-los-angeles-3 usa-new-york usa-chicago usa-phoenix usa-albuquerque
)

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
  command -v ip >/dev/null || { echo "ip command missing"; exit 1; }
  [[ -x "$EXPRESSVPNCTL" ]] || { echo "expressvpnctl not found at $EXPRESSVPNCTL"; exit 1; }
  command -v earnapp >/dev/null || { echo "earnapp not found"; exit 1; }
}

prompt_inputs() {
  if [[ -z "${EXPRESSVPN_KEY:-}" ]]; then
    read -rsp "Enter ExpressVPN activation key/token: " EXPRESSVPN_KEY
    echo
  fi
  if [[ -z "${INSTANCE_COUNT:-}" ]]; then
    read -rp "How many EarnApp instances to run? " INSTANCE_COUNT
  fi
  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "INSTANCE_COUNT must be numeric"; exit 1; }
  (( INSTANCE_COUNT > 0 )) || { echo "INSTANCE_COUNT must be > 0"; exit 1; }
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
}

create_ns() {
  local idx="$1" ns="${BASE_NS}${idx}" host_if="${VETH_PREFIX}${idx}h" ns_if="${VETH_PREFIX}${idx}n"
  local b=$(( (idx-1) / 254 + 1 )) c=$(( (idx-1) % 254 + 1 ))
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
  : > "/etc/netns/$ns/resolv.conf"
  for d in $NS_DNS_LIST; do echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"; done
  echo "$ns"
}

start_expressvpn_in_ns() {
  local ns="$1" region="$2" idx="$3"
  local log="$WORKDIR/expressvpn_${idx}.log" pidfile="$WORKDIR/expressvpn_${idx}.pid"
  ip netns exec "$ns" bash -lc "
    export PATH='$(pwd)/app/expressvpn/bin':\$PATH
    printf '%s' '$EXPRESSVPN_KEY' > '$WORKDIR/code_${idx}.txt'
    '$EXPRESSVPNCTL' login '$WORKDIR/code_${idx}.txt' >/dev/null 2>&1 || true
    '$EXPRESSVPNCTL' set networklock false >/dev/null 2>&1 || true
    '$EXPRESSVPNCTL' set region '$region' >/dev/null 2>&1 || true
    '$EXPRESSVPNCTL' connect '$region'
  " >"$log" 2>&1 &
  echo $! > "$pidfile"
  sleep 3
  ip netns exec "$ns" "$EXPRESSVPNCTL" status >/dev/null 2>&1 || echo "[$idx] warning: expressvpn status check failed"
}

start_earnapp() {
  local ns="$1" idx="$2"
  local inst_dir="$WORKDIR/inst_${idx}" etc_dir="$inst_dir/etc"
  mkdir -p "$etc_dir"
  local uuid_file="$inst_dir/uuid.txt"
  [[ -f "$uuid_file" ]] || printf "sdk-node-%s" "$(uuidgen | tr -d '-' | cut -c1-32)" > "$uuid_file"
  cat "$uuid_file" > "$etc_dir/uuid"
  touch "$etc_dir/status"
  ip netns exec "$ns" unshare -m bash -lc "
    mount --make-rprivate / 2>/dev/null || true
    mkdir -p /etc/earnapp
    mount --bind '$etc_dir' /etc/earnapp
    /usr/bin/earnapp start &
    sleep 5
    exec /usr/bin/earnapp run
  " >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! > "$WORKDIR/app_${idx}.pid"
}

cleanup() {
  for f in "$WORKDIR"/*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#$BASE_NS}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}

trap cleanup EXIT

main() {
  require_root
  prompt_inputs
  setup_nat_once
  local i region ns
  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    region="${REGIONS[$(( (i-1) % ${#REGIONS[@]} ))]}"
    ns="$(create_ns "$i")"
    echo "[$i] Using region: $region (ns=$ns)"
    start_expressvpn_in_ns "$ns" "$region" "$i"
    start_earnapp "$ns" "$i"
  done
  echo "Started $INSTANCE_COUNT EarnApp instances with ExpressVPN."
  wait
}

main "$@"
