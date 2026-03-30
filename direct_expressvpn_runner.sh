#!/usr/bin/env bash
set -euo pipefail

REGIONS=(
"usa-san-francisco" "usa-new-jersey-2" "usa-lincoln-park" "usa-houston" "usa-tampa-1" "usa-new-jersey-3" "usa-brooklyn" "usa-denver"
"usa-dallas" "usa-atlanta" "usa-seattle" "usa-miami-2" "usa-salt-lake-city" "usa-santa-monica" "usa-washington-dc" "usa-new-jersey-1"
"usa-boston" "usa-birmingham" "usa-anchorage" "usa-little-rock" "usa-bridgeport" "usa-wilmington" "usa-honolulu" "usa-boise"
"usa-indianapolis" "usa-des-moines" "usa-wichita" "usa-louisville" "usa-new-orleans" "usa-portland-maine" "usa-baltimore" "usa-detroit"
"usa-minneapolis" "usa-jackson" "usa-st.-louis" "usa-billings" "usa-omaha" "usa-las-vegas" "usa-manchester" "usa-charlotte"
"usa-fargo" "usa-columbus" "usa-oklahoma-city" "usa-portland-oregon" "usa-philadelphia" "usa-providence"
"usa-charleston-south-carolina" "usa-sioux-falls" "usa-nashville" "usa-burlington" "usa-virginia-beach"
"usa-charleston-west-virginia" "usa-milwaukee" "usa-cheyenne" "usa-miami" "usa-los-angeles-1" "usa-los-angeles-2"
"usa-los-angeles-5" "usa-los-angeles-3" "usa-new-york" "usa-chicago" "usa-phoenix" "usa-albuquerque"
"costa-rica" "thailand" "greece" "france-strasbourg" "france-paris-1" "france-alsace" "france-marseille" "france-paris-2" "israel" "iceland"
"singapore-cbd" "singapore-jurong" "singapore-marina-bay" "taiwan-3" "south-africa" "switzerland" "switzerland-2" "bulgaria" "malaysia"
"indonesia" "new-zealand" "hong-kong-2" "hong-kong-1" "bahamas" "vietnam" "croatia" "liechtenstein" "luxembourg" "moldova" "slovenia"
"latvia" "cyprus" "chile" "albania" "slovakia" "uzbekistan" "isle-of-man" "estonia" "colombia" "mexico" "kazakhstan" "malta" "georgia"
"mongolia" "algeria" "uruguay" "guatemala" "peru" "venezuela" "ecuador" "serbia" "north-macedonia" "bosnia-and-herzegovina"
"uk-midlands" "uk-east-london" "uk-tottenham" "uk-london" "uk-docklands" "uk-wembley" "india-(via-uk)" "india-(via-singapore)"
"australia-melbourne" "australia-sydney-2" "australia-brisbane" "australia-perth" "australia-woolloomooloo" "australia-sydney" "australia-adelaide"
"italy-milan" "italy-cosenza" "italy-naples" "netherlands-rotterdam" "netherlands-the-hague" "netherlands-amsterdam" "brazil-2" "brazil"
"philippines" "canada-toronto-2" "canada-vancouver" "canada-montreal" "canada-toronto" "macau" "cambodia" "kenya" "andorra" "armenia"
"belarus" "monaco" "jersey" "montenegro" "bangladesh" "bhutan" "brunei" "laos" "myanmar" "nepal" "pakistan" "sri-lanka" "panama"
"sweden-2" "sweden" "austria" "germany-nuremberg" "germany-frankfurt-1" "germany-frankfurt-3" "spain-barcelona" "spain-madrid"
"spain-barcelona-2" "japan-yokohama" "japan-tokyo" "japan-shibuya" "japan-osaka" "bolivia" "guam" "ghana" "dominican-republic" "jamaica"
"puerto-rico" "bermuda" "trinidad-and-tobago" "cayman-islands" "cuba" "honduras" "lebanon" "morocco" "united-arab-emirates"
"azerbaijan" "portugal" "poland" "ireland" "finland" "lithuania" "czech-republic" "south-korea-2" "denmark" "egypt" "belgium"
"romania" "ukraine" "argentina" "turkey" "norway" "hungary"
)

: "${APP_NAME:?APP_NAME is required}"
: "${APP_RUN_CMD:?APP_RUN_CMD is required}"
BASE_NS="${BASE_NS:-${APP_NAME}ns}"
VETH_PREFIX="${VETH_PREFIX:-${APP_NAME}}"
WORKDIR="${WORKDIR:-/tmp/${APP_NAME}_expressvpn}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPRESSVPN_SRC="${EXPRESSVPN_SRC:-$REPO_DIR/app/expressvpn}"
EXPRESSVPN_BIN_SRC="${EXPRESSVPN_BIN_SRC:-$EXPRESSVPN_SRC/bin}"
EXPRESSVPN_SCRIPT_SRC="${EXPRESSVPN_SCRIPT_SRC:-$EXPRESSVPN_SRC/script}"
EXPRESSVPN_SERVICE_SRC="${EXPRESSVPN_SERVICE_SRC:-$EXPRESSVPN_SRC/expressvpn-service}"

mkdir -p "$WORKDIR"
PIDS=()
NETNS_LIST=()

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }
  command -v ip >/dev/null || { echo "iproute2 missing"; exit 1; }
  command -v unshare >/dev/null || { echo "unshare missing"; exit 1; }
  [[ -x "$EXPRESSVPN_BIN_SRC/expressvpnctl" ]] || { echo "Missing $EXPRESSVPN_BIN_SRC/expressvpnctl"; exit 1; }
  [[ -f "$EXPRESSVPN_SERVICE_SRC" ]] || { echo "Missing $EXPRESSVPN_SERVICE_SRC"; exit 1; }
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! iptables -t nat -C POSTROUTING -s 10.123.0.0/16 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.123.0.0/16 -j MASQUERADE
  fi
}

create_ns() {
  local idx="$1" ns="${BASE_NS}${idx}" host_if="${VETH_PREFIX}${idx}h" ns_if="${VETH_PREFIX}${idx}n"
  local b=$(( (idx - 1) / 254 + 1 )) c=$(( (idx - 1) % 254 + 1 ))
  ip netns add "$ns" 2>/dev/null || true
  ip link add "$host_if" type veth peer name "$ns_if" 2>/dev/null || true
  ip link set "$ns_if" netns "$ns"
  ip addr add "10.123.${b}.${c}.1/24" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip addr add "10.123.${b}.${c}.2/24" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.123.${b}.${c}.1" dev "$ns_if"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  NETNS_LIST+=("$ns")
}

ask_inputs() {
  read -rsp "Enter ExpressVPN activation key: " EXPRESSVPN_CODE
  echo
  [[ -n "${EXPRESSVPN_CODE:-}" ]] || { echo "Activation key is required"; exit 1; }
  read -rp "How many ${APP_NAME} instances do you want to run? " INSTANCE_COUNT
  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] && (( INSTANCE_COUNT > 0 )) || { echo "Invalid instance count"; exit 1; }
  REGIONS_SELECTED=()
  for ((i=1;i<=INSTANCE_COUNT;i++)); do
    local dflt="${REGIONS[$(( (i-1) % ${#REGIONS[@]} ))]}" answer
    read -rp "Region for instance $i [${dflt}]: " answer
    answer="${answer:-$dflt}"
    answer="${answer#\'}"; answer="${answer%\'}"
    REGIONS_SELECTED+=("$answer")
  done
}

launch_instance() {
  local idx="$1" region="$2" ns="${BASE_NS}${idx}" inst_dir="$WORKDIR/instance_${idx}"
  local runtime_dir="/tmp/${APP_NAME}_runtime_${idx}"
  mkdir -p "$inst_dir" "$runtime_dir" "$inst_dir/app_home"
  rm -rf "$inst_dir/opt_expressvpn"
  mkdir -p "$inst_dir/opt_expressvpn"

  if [[ -d "$EXPRESSVPN_BIN_SRC" ]]; then
    cp -a "$EXPRESSVPN_BIN_SRC" "$inst_dir/opt_expressvpn/"
  fi
  [[ -d "$EXPRESSVPN_SRC/lib" ]] && cp -a "$EXPRESSVPN_SRC/lib" "$inst_dir/opt_expressvpn/"
  [[ -d "$EXPRESSVPN_SRC/share" ]] && cp -a "$EXPRESSVPN_SRC/share" "$inst_dir/opt_expressvpn/"
  [[ -d "$EXPRESSVPN_SRC/etc" ]] && cp -a "$EXPRESSVPN_SRC/etc" "$inst_dir/opt_expressvpn/"
  cp -f "$EXPRESSVPN_SERVICE_SRC" "$inst_dir/expressvpn-service"
  chmod +x "$inst_dir/expressvpn-service"

  create_ns "$idx"
  echo "[$idx] starting isolated ExpressVPN in $ns region=$region"

  ip netns exec "$ns" unshare -m bash -lc "
    set -e
    mount --make-rprivate /
    mkdir -p /opt/expressvpn /expressvpn /etc/init.d
    mount --bind '$inst_dir/opt_expressvpn' /opt/expressvpn
    mount --bind '$EXPRESSVPN_SCRIPT_SRC' /expressvpn
    mount --bind '$inst_dir/expressvpn-service' /etc/init.d/expressvpn-service
    chmod +x /etc/init.d/expressvpn-service /expressvpn/*.sh
    export PATH=/opt/expressvpn/bin:\$PATH
    export LD_LIBRARY_PATH=/opt/expressvpn/lib:\${LD_LIBRARY_PATH:-}
    export CODE='$EXPRESSVPN_CODE'
    export SERVER='$region'
    export XVPN_RUNTIME_DIR='$runtime_dir'
    export METRICS_PROMETHEUS=off CONTROL_SERVER=off SOCKS=off
    nohup bash /expressvpn/start.sh >'$inst_dir/expressvpn.log' 2>&1 &
    echo \$! > '$inst_dir/expressvpn.pid'
  "

  ip netns exec "$ns" bash -lc 'for i in {1..90}; do [[ -d /sys/class/net/tun0 ]] && exit 0; sleep 1; done; exit 1' || {
    echo "[$idx] tun0 did not appear. check $inst_dir/expressvpn.log"
    return 1
  }

  ip netns exec "$ns" bash -lc '
    iptables -F
    iptables -P INPUT DROP
    iptables -P OUTPUT DROP
    iptables -P FORWARD DROP
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i tun0 -j ACCEPT
    iptables -A OUTPUT -o tun0 -j ACCEPT
  '

  ip netns exec "$ns" bash -lc "
    export HOME='$inst_dir/app_home'
    export XVPN_RUNTIME_DIR='$runtime_dir'
    export XXX_RUNTIME_DIR='/tmp'
    cd '$REPO_DIR'
    nohup bash -lc '$APP_RUN_CMD' >'$inst_dir/app.log' 2>&1 &
    echo \$! > '$inst_dir/app.pid'
  "

  PIDS+=("$inst_dir")
  echo "[$idx] ${APP_NAME} started in ${ns}; logs: $inst_dir"
}

cleanup() {
  set +e
  for inst in "${PIDS[@]:-}"; do
    [[ -f "$inst/app.pid" ]] && kill "$(cat "$inst/app.pid")" 2>/dev/null || true
    [[ -f "$inst/expressvpn.pid" ]] && kill "$(cat "$inst/expressvpn.pid")" 2>/dev/null || true
  done
  for ns in "${NETNS_LIST[@]:-}"; do
    local idx="${ns#${BASE_NS}}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}

main() {
  trap cleanup EXIT INT TERM
  require_root
  setup_nat_once
  ask_inputs
  for ((i=1;i<=INSTANCE_COUNT;i++)); do
    launch_instance "$i" "${REGIONS_SELECTED[$((i-1))]}"
  done
  echo "All instances running with complete namespace isolation. Press Ctrl+C to stop."
  wait
}

main "$@"
