#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPRESSVPNCTL="$BASE_DIR/app/expressvpn/bin/expressvpnctl"
HOST_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[ -n "$HOST_IF" ] || HOST_IF="eth0"

PIDS=()
CREATED_NETNS=()
CREATED_SUBNETS=()
EXITING=0
NS_COUNTER=20

TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
EXPRESSVPN_TOKEN=""
INSTANCE_COUNT=1

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
  costa-rica thailand greece france-strasbourg france-paris-1 france-alsace france-marseille france-paris-2 israel iceland
  singapore-cbd singapore-jurong singapore-marina-bay taiwan-3 south-africa switzerland switzerland-2 bulgaria malaysia indonesia new-zealand
  hong-kong-2 hong-kong-1 bahamas vietnam croatia liechtenstein luxembourg moldova slovenia latvia cyprus chile albania slovakia
  uzbekistan isle-of-man estonia colombia mexico kazakhstan malta georgia mongolia algeria uruguay guatemala peru venezuela ecuador
  serbia north-macedonia bosnia-and-herzegovina uk-midlands uk-east-london uk-tottenham uk-london uk-docklands uk-wembley
  "india-(via-uk)" "india-(via-singapore)" australia-melbourne australia-sydney-2 australia-brisbane australia-perth australia-woolloomooloo
  australia-sydney australia-adelaide italy-milan italy-cosenza italy-naples netherlands-rotterdam netherlands-the-hague netherlands-amsterdam
  brazil-2 brazil philippines canada-toronto-2 canada-vancouver canada-montreal canada-toronto macau cambodia kenya andorra armenia belarus
  monaco jersey montenegro bangladesh bhutan brunei laos myanmar nepal pakistan sri-lanka panama sweden-2 sweden austria
  germany-nuremberg germany-frankfurt-1 germany-frankfurt-3 spain-barcelona spain-madrid spain-barcelona-2 japan-yokohama japan-tokyo
  japan-shibuya japan-osaka bolivia guam ghana dominican-republic jamaica puerto-rico bermuda trinidad-and-tobago cayman-islands cuba honduras
  lebanon morocco united-arab-emirates azerbaijan portugal poland ireland finland lithuania czech-republic south-korea-2 denmark egypt belgium
  romania ukraine argentina turkey norway hungary
)

stop_tracked_pids() {
  local pid
  for pid in "${PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in "${PIDS[@]:-}"; do kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true; done
}

cleanup() {
  [[ "$EXITING" == "1" ]] && return
  EXITING=1
  echo -e "\nStopping all running services and VPN namespaces..."
  stop_tracked_pids
  for subnet in "${CREATED_SUBNETS[@]:-}"; do
    sudo iptables -t nat -D POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || true
  done
  for ns in "${CREATED_NETNS[@]:-}"; do
    sudo ip netns exec "$ns" "$EXPRESSVPNCTL" disconnect >/dev/null 2>&1 || true
    sudo ip netns delete "$ns" 2>/dev/null || true
    sudo rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
  echo "Cleanup complete."
  exit 0
}
trap cleanup INT TERM

install_dependencies() {
  sudo apt update
  sudo apt install -y curl wget unzip iproute2 iptables jq net-tools
}

ask_tokens() {
  echo "========== APP TOKEN SETUP =========="
  read -rp "Enter Traff token (or leave blank): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (or leave blank): " PS_TOKEN
  read -rp "Enter Castar Key (or leave blank): " CASTAR_KEY
  echo "====================================="
}

ask_expressvpn_setup() {
  [[ -x "$EXPRESSVPNCTL" ]] || {
    echo "expressvpnctl not found: $EXPRESSVPNCTL"
    exit 1
  }

  read -rp "Enter ExpressVPN activation key/token file path (required): " EXPRESSVPN_TOKEN
  while [[ -z "$EXPRESSVPN_TOKEN" ]]; do
    read -rp "ExpressVPN key cannot be empty. Enter key/token file path: " EXPRESSVPN_TOKEN
  done

  read -rp "How many instances do you want to run per app? " INSTANCE_COUNT
  while ! [[ "$INSTANCE_COUNT" =~ ^[1-9][0-9]*$ ]]; do
    read -rp "Enter a valid number (>0): " INSTANCE_COUNT
  done

  echo "Region assignment for instances (repeats when list ends):"
  local i idx
  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    idx=$(( (i-1) % ${#REGIONS[@]} ))
    echo "  Instance $i -> ${REGIONS[$idx]}"
  done
}

create_netns_with_veth() {
  local ns="$1"
  local idx="$2"

  echo "Creating namespace $ns (idx=$idx)..."
  sudo ip netns add "$ns"
  CREATED_NETNS+=("$ns")

  local host_if="v${idx}h"
  local ns_if="v${idx}n"
  local host_ip="10.210.${idx}.1/24"
  local ns_ip="10.210.${idx}.2/24"
  local subnet="10.210.${idx}.0/24"

  sudo ip link add "$host_if" type veth peer name "$ns_if"
  sudo ip link set "$ns_if" netns "$ns"
  sudo ip addr add "$host_ip" dev "$host_if" || true
  sudo ip link set "$host_if" up
  sudo ip netns exec "$ns" ip addr add "$ns_ip" dev "$ns_if"
  sudo ip netns exec "$ns" ip link set "$ns_if" up
  sudo ip netns exec "$ns" ip link set lo up
  sudo ip netns exec "$ns" ip route replace default via "10.210.${idx}.1"

  sudo mkdir -p "/etc/netns/$ns"
  echo "nameserver 1.1.1.1" | sudo tee "/etc/netns/$ns/resolv.conf" >/dev/null
  echo "nameserver 8.8.8.8" | sudo tee -a "/etc/netns/$ns/resolv.conf" >/dev/null

  sudo iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
  CREATED_SUBNETS+=("$subnet")
}

connect_expressvpn_in_ns() {
  local ns="$1"
  local region="$2"

  echo "[$ns] Logging in and connecting ExpressVPN region=$region"
  sudo ip netns exec "$ns" bash -lc "
    set -e
    '$EXPRESSVPNCTL' login '$EXPRESSVPN_TOKEN' >/tmp/${ns}_vpn_login.log 2>&1 || true
    '$EXPRESSVPNCTL' set networklock false >/tmp/${ns}_vpn_networklock.log 2>&1 || true
    '$EXPRESSVPNCTL' set region '$region' >/tmp/${ns}_vpn_region.log 2>&1
    '$EXPRESSVPNCTL' connect '$region' >/tmp/${ns}_vpn_connect.log 2>&1
    '$EXPRESSVPNCTL' status >/tmp/${ns}_vpn_status.log 2>&1
  "
}

start_app_in_ns() {
  local ns="$1"
  local app_name="$2"
  local cmd="$3"
  echo "[$ns] Starting $app_name"
  sudo ip netns exec "$ns" bash -lc "nohup $cmd >/tmp/${ns}_${app_name}.log 2>&1 & echo \$!" | {
    read -r pid
    [[ -n "${pid:-}" ]] && PIDS+=("$pid")
  }
}

run_app_instances() {
  local app_key="$1"
  local app_name="$2"
  local cmd="$3"

  local i idx region region_idx ns
  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    NS_COUNTER=$((NS_COUNTER+1))
    idx="$NS_COUNTER"
    ns="${app_key}${i}ns"
    region_idx=$(( (i-1) % ${#REGIONS[@]} ))
    region="${REGIONS[$region_idx]}"

    create_netns_with_veth "$ns" "$idx"
    connect_expressvpn_in_ns "$ns" "$region"
    start_app_in_ns "$ns" "$app_key" "$cmd"
  done

  echo "$app_name started with $INSTANCE_COUNT instance(s)."
}

run_earnapp() {
  run_app_instances "earnapp" "EarnApp" "earnapp start"
}

run_traff() {
  [[ -n "$TRAFF_TOKEN" ]] || { echo "Traff token not set."; return; }
  run_app_instances "traff" "Traff" "./app/cli start accept --token '$TRAFF_TOKEN'"
}

run_packetstream() {
  [[ -n "$PS_TOKEN" ]] || { echo "PacketStream token not set."; return; }
  run_app_instances "packetstream" "PacketStream" "env CID='$PS_TOKEN' PS_IS_DOCKER=true ./app/psclient"
}

run_urnetwork() {
  if [[ ! -f "$HOME/.urnetwork/jwt" ]]; then
    ./app/provider auth
  fi
  run_app_instances "urnetwork" "UrNetwork" "./app/provider provide"
}

run_castar() {
  [[ -n "$CASTAR_KEY" ]] || { echo "Castar key not set."; return; }
  run_app_instances "castar" "Castar" "./app/CastarSDK -key='$CASTAR_KEY'"
}

install_expressvpn_hint() {
  echo "This project now expects ExpressVPN CLI binaries in: ./app/expressvpn/bin/"
  echo "Verify: $EXPRESSVPNCTL"
  [[ -x "$EXPRESSVPNCTL" ]] && "$EXPRESSVPNCTL" --help | head -n 20 || true
}

menu() {
  echo -e "\n====== GRAND NETWORK MANAGER (EXPRESSVPN NETNS) ======"
  echo "1) Run EarnApp (ExpressVPN)"
  echo "2) Run Traff (ExpressVPN)"
  echo "3) Run PacketStream (ExpressVPN)"
  echo "4) Run UrNetwork (ExpressVPN)"
  echo "5) Run Castar (ExpressVPN)"
  echo "6) Check ExpressVPN CLI"
  echo "7) Install Dependencies"
  echo "9) Run ALL (ExpressVPN)"
  echo "0) Exit"
  echo "======================================================="
}

install_dependencies
ask_tokens
ask_expressvpn_setup

while true; do
  menu
  read -rp "Select option: " opt || cleanup
  case "$opt" in
    1) run_earnapp ; wait ;;
    2) run_traff ; wait ;;
    3) run_packetstream ; wait ;;
    4) run_urnetwork ; wait ;;
    5) run_castar ; wait ;;
    6) install_expressvpn_hint ; wait ;;
    7) install_dependencies ; wait ;;
    9)
      run_earnapp
      run_traff
      run_packetstream
      run_urnetwork
      run_castar
      echo "All selected services running via ExpressVPN per namespace. Press Ctrl+C to stop."
      wait
      ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done
