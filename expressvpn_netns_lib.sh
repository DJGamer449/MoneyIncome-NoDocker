#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPRESSVPN_SRC="$BASE_DIR/app/expressvpn"
SCRIPT_MOUNT_SRC="$BASE_DIR/app/expressvpn/script"
SERVICE_TEMPLATE="$BASE_DIR/app/expressvpn/expressvpn-service"

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
"costa-rica" "thailand" "greece" "france-strasbourg" "france-paris-1" "france-alsace" "france-marseille" "france-paris-2"
"israel" "iceland" "singapore-cbd" "singapore-jurong" "singapore-marina-bay" "taiwan-3" "south-africa" "switzerland" "switzerland-2"
"bulgaria" "malaysia" "indonesia" "new-zealand" "hong-kong-2" "hong-kong-1" "bahamas" "vietnam" "croatia" "liechtenstein"
"luxembourg" "moldova" "slovenia" "latvia" "cyprus" "chile" "albania" "slovakia" "uzbekistan" "isle-of-man" "estonia" "colombia"
"mexico" "kazakhstan" "malta" "georgia" "mongolia" "algeria" "uruguay" "guatemala" "peru" "venezuela" "ecuador" "serbia"
"north-macedonia" "bosnia-and-herzegovina" "uk-midlands" "uk-east-london" "uk-tottenham" "uk-london" "uk-docklands" "uk-wembley"
"india-(via-uk)" "india-(via-singapore)" "australia-melbourne" "australia-sydney-2" "australia-brisbane" "australia-perth" "australia-woolloomooloo" "australia-sydney" "australia-adelaide"
"italy-milan" "italy-cosenza" "italy-naples" "netherlands-rotterdam" "netherlands-the-hague" "netherlands-amsterdam" "brazil-2" "brazil" "philippines"
"canada-toronto-2" "canada-vancouver" "canada-montreal" "canada-toronto" "macau" "cambodia" "kenya" "andorra" "armenia" "belarus" "monaco"
"jersey" "montenegro" "bangladesh" "bhutan" "brunei" "laos" "myanmar" "nepal" "pakistan" "sri-lanka" "panama" "sweden-2" "sweden" "austria"
"germany-nuremberg" "germany-frankfurt-1" "germany-frankfurt-3" "spain-barcelona" "spain-madrid" "spain-barcelona-2" "japan-yokohama" "japan-tokyo" "japan-shibuya" "japan-osaka"
"bolivia" "guam" "ghana" "dominican-republic" "jamaica" "puerto-rico" "bermuda" "trinidad-and-tobago" "cayman-islands" "cuba" "honduras"
"lebanon" "morocco" "united-arab-emirates" "azerbaijan" "portugal" "poland" "ireland" "finland" "lithuania" "czech-republic" "south-korea-2"
"denmark" "egypt" "belgium" "romania" "ukraine" "argentina" "turkey" "norway" "hungary"
)

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root/sudo."; exit 1; }; }

prompt_vpn_inputs() {
  read -rsp "Enter ExpressVPN activation key: " VPN_ACTIVATION_KEY; echo
  [[ -n "$VPN_ACTIVATION_KEY" ]] || { echo "Activation key is required."; exit 1; }
  read -rp "How many instances do you want to run? " INSTANCE_COUNT
  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "Instance count must be numeric."; exit 1; }
  (( INSTANCE_COUNT > 0 )) || { echo "Instance count must be > 0."; exit 1; }

  REGIONS_SELECTED=()
  local i default_region selected
  for ((i=1;i<=INSTANCE_COUNT;i++)); do
    default_region="${REGIONS[$(( (i-1) % ${#REGIONS[@]} ))]}"
    read -rp "Region for instance ${i} [${default_region}]: " selected
    selected="${selected:-$default_region}"
    REGIONS_SELECTED+=("$selected")
  done
}

setup_netns() {
  local ns="$1" idx="$2" host_if
  host_if="$(ip route show default | awk '/default/ {print $5; exit}')"
  [[ -n "$host_if" ]] || host_if="eth0"

  ip netns add "$ns" 2>/dev/null || true
  ip link del "vethh${idx}" 2>/dev/null || true
  ip link add "vethh${idx}" type veth peer name "vethn${idx}"
  ip link set "vethn${idx}" netns "$ns"
  ip addr add "10.210.${idx}.1/24" dev "vethh${idx}" 2>/dev/null || true
  ip link set "vethh${idx}" up
  ip netns exec "$ns" ip addr add "10.210.${idx}.2/24" dev "vethn${idx}" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "vethn${idx}" up
  ip netns exec "$ns" ip route replace default via "10.210.${idx}.1" dev "vethn${idx}"
  mkdir -p "/etc/netns/${ns}"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"/etc/netns/${ns}/resolv.conf"
  iptables -t nat -C POSTROUTING -s "10.210.${idx}.0/24" -o "$host_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "10.210.${idx}.0/24" -o "$host_if" -j MASQUERADE
}

prepare_expressvpn_instance() {
  local ns="$1"
  local inst_root="/opt/expressvpn/${ns}"
  local service_file="${inst_root}/expressvpn-service"
  mkdir -p "$inst_root"
  cp -a "$EXPRESSVPN_SRC/bin" "$EXPRESSVPN_SRC/lib" "$EXPRESSVPN_SRC/share" "$EXPRESSVPN_SRC/qml" "$inst_root/"
  sed \
    -e "s|^DAEMON=.*|DAEMON=${inst_root}/bin/expressvpn-daemon|" \
    -e "s|^NAME=.*|NAME=expressvpn-service-${ns}|" \
    -e "s|^PIDFILE=.*|PIDFILE=\"/var/run/expressvpn-service-${ns}.pid\"|" \
    -e "s|^export LD_LIBRARY_PATH=.*|export LD_LIBRARY_PATH=${inst_root}/lib|" \
    "$SERVICE_TEMPLATE" > "$service_file"
  chmod +x "$service_file"
}

run_instance() {
  local ns="$1" region="$2" app_cmd="$3" app_log="$4"
  local inst_root="/opt/expressvpn/${ns}"
  ip netns exec "$ns" unshare -m bash -lc "
    set -e
    mount --make-rprivate /
    mkdir -p /opt/expressvpn /etc/init.d /expressvpn /tmp/expressvpn/${ns}
    mount --bind '${inst_root}' /opt/expressvpn
    mount --bind '${SCRIPT_MOUNT_SRC}' /expressvpn
    cp '${inst_root}/expressvpn-service' /etc/init.d/expressvpn-service
    chmod +x /etc/init.d/expressvpn-service /expressvpn/*.sh
    export PATH=/opt/expressvpn/bin:\$PATH
    export LD_LIBRARY_PATH=/opt/expressvpn/lib
    export EXPRESSVPN_INSTANCE_ROOT=/tmp/expressvpn/${ns}
    export EXPRESSVPN_FAILURE_FLAG=/tmp/expressvpn/${ns}/reconnect-failure.flag
    CODE='${VPN_ACTIVATION_KEY}' SERVER='${region}' ALLOW_LAN=false PROTOCOL=lightwayudp /expressvpn/start.sh bash -lc ${app_cmd@Q}
  " >"$app_log" 2>&1 &
  echo $! >"${app_log}.pid"
}
