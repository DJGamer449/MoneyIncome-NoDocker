#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$BASE_DIR/app/expressvpn/bin}"
WORKDIR="${WORKDIR:-/tmp/expressvpn_multi}"
BASE_NS="${BASE_NS:-vpnns}"
APP_NAME="${APP_NAME:-app}"
APP_CMD="${APP_CMD:-}"
DNS_SERVERS=(1.1.1.1 8.8.8.8)

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
  costa-rica thailand greece
  france-strasbourg france-paris-1 france-alsace france-marseille france-paris-2
  israel iceland
  singapore-cbd singapore-jurong singapore-marina-bay
  taiwan-3 south-africa
  switzerland switzerland-2
  bulgaria malaysia indonesia new-zealand
  hong-kong-2 hong-kong-1 bahamas vietnam
  croatia liechtenstein luxembourg moldova slovenia latvia cyprus chile albania slovakia uzbekistan isle-of-man estonia
  colombia mexico kazakhstan malta georgia mongolia algeria uruguay guatemala peru venezuela ecuador
  serbia north-macedonia bosnia-and-herzegovina
  uk-midlands uk-east-london uk-tottenham uk-london uk-docklands uk-wembley
  'india-(via-uk)' 'india-(via-singapore)'
  australia-melbourne australia-sydney-2 australia-brisbane australia-perth australia-woolloomooloo australia-sydney australia-adelaide
  italy-milan italy-cosenza italy-naples
  netherlands-rotterdam netherlands-the-hague netherlands-amsterdam
  brazil-2 brazil philippines
  canada-toronto-2 canada-vancouver canada-montreal canada-toronto
  macau cambodia kenya
  andorra armenia belarus monaco jersey montenegro
  bangladesh bhutan brunei laos myanmar nepal pakistan sri-lanka panama
  sweden-2 sweden austria
  germany-nuremberg germany-frankfurt-1 germany-frankfurt-3
  spain-barcelona spain-madrid spain-barcelona-2
  japan-yokohama japan-tokyo japan-shibuya japan-osaka
  bolivia guam ghana dominican-republic jamaica puerto-rico bermuda trinidad-and-tobago cayman-islands cuba honduras
  lebanon morocco united-arab-emirates azerbaijan
  portugal poland ireland finland lithuania czech-republic
  south-korea-2 denmark egypt belgium romania ukraine
  argentina turkey norway hungary
)

require_cmds() {
  local req=(ip iptables bash)
  for c in "${req[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { echo "Missing command: $c"; exit 1; }
  done
  [[ -x "$EXPRESSVPN_BIN_DIR/expressvpnctl" ]] || { echo "Missing $EXPRESSVPN_BIN_DIR/expressvpnctl"; exit 1; }
  [[ -x "$EXPRESSVPN_BIN_DIR/expressvpn-daemon" ]] || { echo "Missing $EXPRESSVPN_BIN_DIR/expressvpn-daemon"; exit 1; }
  [[ -n "$APP_CMD" ]] || { echo "APP_CMD is required"; exit 1; }
}

setup_ns() {
  local ns="$1" idx="$2"
  local host_if="${BASE_NS}h${idx}"
  local ns_if="${BASE_NS}n${idx}"
  local subnet="10.210.${idx}.0/24"

  ip netns add "$ns" 2>/dev/null || true
  ip link add "$host_if" type veth peer name "$ns_if" 2>/dev/null || true
  ip addr add "10.210.${idx}.1/24" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip link set "$ns_if" netns "$ns"

  ip netns exec "$ns" ip addr add "10.210.${idx}.2/24" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.210.${idx}.1" dev "$ns_if"

  mkdir -p "/etc/netns/$ns"
  : > "/etc/netns/$ns/resolv.conf"
  for d in "${DNS_SERVERS[@]}"; do echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"; done

  iptables -t nat -C POSTROUTING -s "$subnet" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$subnet" -j MASQUERADE
}

start_instance() {
  local idx="$1" region="$2" protocol="$3" activation_code="$4"
  local ns="${BASE_NS}${idx}"
  local inst="$WORKDIR/${APP_NAME}_${idx}"
  mkdir -p "$inst/home" "$inst/run"

  setup_ns "$ns" "$idx"
  groupadd -f expressvpn >/dev/null 2>&1 || true

  ip netns exec "$ns" bash -lc "
    export HOME='$inst/home'
    cd '$EXPRESSVPN_BIN_DIR'
    nohup ./expressvpn-daemon >'$inst/expressvpn-daemon.log' 2>&1 &
    echo \$! > '$inst/expressvpn-daemon.pid'
    sleep 2
    ./expressvpnctl background enable
    ./expressvpnctl set networklock true
    ./expressvpnctl set auto_connect true
    ./expressvpnctl set region '$region'
    ./expressvpnctl set protocol '$protocol'
    ./expressvpnctl login <(echo '$activation_code')
    ./expressvpnctl connect '$region'
  "

  ip netns exec "$ns" bash -lc "
    export HOME='$inst/home'
    cd '$BASE_DIR'
    nohup $APP_CMD >'$inst/${APP_NAME}.log' 2>&1 &
    echo \$! > '$inst/${APP_NAME}.pid'
  "

  echo "[$idx] ${APP_NAME} running in ${ns} via region ${region}."
}

cleanup() {
  for f in "$WORKDIR"/*/"${APP_NAME}.pid"; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for f in "$WORKDIR"/*/expressvpn-daemon.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}

main() {
  require_cmds
  mkdir -p "$WORKDIR"

  read -rsp "Enter ExpressVPN activation code: " ACTIVATION_CODE
  echo
  [[ -n "$ACTIVATION_CODE" ]] || { echo "Activation code required"; exit 1; }

  local instances
  read -rp "How many ${APP_NAME} instances do you want to run? " instances
  [[ "$instances" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid instance count"; exit 1; }

  local protocol="auto"
  read -rp "Protocol for all instances [auto/lightway_tcp/lightway_udp/openvpn_udp/openvpn_tcp] (default: auto): " protocol
  protocol="${protocol:-auto}"

  trap cleanup INT TERM

  local total_regions="${#REGIONS[@]}"
  local i region_idx region
  for ((i=1; i<=instances; i++)); do
    region_idx=$(( (i-1) % total_regions ))
    region="${REGIONS[$region_idx]}"
    start_instance "$i" "$region" "$protocol" "$ACTIVATION_CODE"
  done

  echo "All ${APP_NAME} instances started. Press Ctrl+C to stop and clean up."
  wait
}

main "$@"
