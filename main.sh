#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EARNAPP_SCRIPT="$BASE_DIR/direct_earnapp.sh"
TRAFF_SCRIPT="$BASE_DIR/direct_traff.sh"
CASTAR_SCRIPT="$BASE_DIR/direct_castar.sh"
UR_SCRIPT="$BASE_DIR/direct_urnetwork.sh"
WIPTER_SCRIPT="$BASE_DIR/direct_wipter.sh"
HONEYGAIN_SCRIPT="$BASE_DIR/direct_honeygain.sh"
MYSTERIUM_SCRIPT="$BASE_DIR/direct_mysterium.sh"
MYST_INSTALL_SCRIPT="$BASE_DIR/install_mysterium_node.sh"

PIDS=()
TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
WIPTER_EMAIL=""
WIPTER_PASSWORD=""
HONEYGAIN_EMAIL=""
HONEYGAIN_PASSWORD=""
EXPRESSVPN_ACTIVATION_KEY=""
INSTANCE_COUNT=1

REGIONS_RAW=$(cat <<'REGIONS'
usa-san-francisco
usa-new-jersey-2
usa-lincoln-park
usa-houston
usa-tampa-1
usa-new-jersey-3
usa-brooklyn
usa-denver
usa-dallas
usa-atlanta
usa-seattle
usa-miami-2
usa-salt-lake-city
usa-santa-monica
usa-washington-dc
usa-new-jersey-1
usa-boston
usa-birmingham
usa-anchorage
usa-little-rock
usa-bridgeport
usa-wilmington
usa-honolulu
usa-boise
usa-indianapolis
usa-des-moines
usa-wichita
usa-louisville
usa-new-orleans
usa-portland-maine
usa-baltimore
usa-detroit
usa-minneapolis
usa-jackson
usa-st.-louis
usa-billings
usa-omaha
usa-las-vegas
usa-manchester
usa-charlotte
usa-fargo
usa-columbus
usa-oklahoma-city
usa-portland-oregon
usa-philadelphia
usa-providence
usa-charleston-south-carolina
usa-sioux-falls
usa-nashville
usa-burlington
usa-virginia-beach
usa-charleston-west-virginia
usa-milwaukee
usa-cheyenne
usa-miami
usa-los-angeles-1
usa-los-angeles-2
usa-los-angeles-5
usa-los-angeles-3
usa-new-york
usa-chicago
usa-phoenix
usa-albuquerque
costa-rica
thailand
greece
france-strasbourg
france-paris-1
france-alsace
france-marseille
france-paris-2
israel
iceland
singapore-cbd
singapore-jurong
singapore-marina-bay
taiwan-3
south-africa
switzerland
switzerland-2
bulgaria
malaysia
indonesia
new-zealand
hong-kong-2
hong-kong-1
bahamas
vietnam
croatia
liechtenstein
luxembourg
moldova
slovenia
latvia
cyprus
chile
albania
slovakia
uzbekistan
isle-of-man
estonia
colombia
mexico
kazakhstan
malta
georgia
mongolia
algeria
uruguay
guatemala
peru
venezuela
ecuador
serbia
north-macedonia
bosnia-and-herzegovina
uk-midlands
uk-east-london
uk-tottenham
uk-london
uk-docklands
uk-wembley
india-(via-uk)
india-(via-singapore)
australia-melbourne
australia-sydney-2
australia-brisbane
australia-perth
australia-woolloomooloo
australia-sydney
australia-adelaide
italy-milan
italy-cosenza
italy-naples
netherlands-rotterdam
netherlands-the-hague
netherlands-amsterdam
brazil-2
brazil
philippines
canada-toronto-2
canada-vancouver
canada-montreal
canada-toronto
macau
cambodia
kenya
andorra
armenia
belarus
monaco
jersey
montenegro
bangladesh
bhutan
brunei
laos
myanmar
nepal
pakistan
sri-lanka
panama
sweden-2
sweden
austria
germany-nuremberg
germany-frankfurt-1
germany-frankfurt-3
spain-barcelona
spain-madrid
spain-barcelona-2
japan-yokohama
japan-tokyo
japan-shibuya
japan-osaka
bolivia
guam
ghana
dominican-republic
jamaica
puerto-rico
bermuda
trinidad-and-tobago
cayman-islands
cuba
honduras
lebanon
morocco
united-arab-emirates
azerbaijan
portugal
poland
ireland
finland
lithuania
czech-republic
south-korea-2
denmark
egypt
belgium
romania
ukraine
argentina
turkey
norway
hungary
REGIONS
)

ask_inputs() {
  read -rp "ExpressVPN activation key: " EXPRESSVPN_ACTIVATION_KEY
  read -rp "How many isolated instances per app? [1]: " INSTANCE_COUNT
  INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
  read -rp "Traff token (optional): " TRAFF_TOKEN
  read -rp "PacketStream CID (optional): " PS_TOKEN
  read -rp "Castar key (optional): " CASTAR_KEY
  read -rp "Wipter email (optional): " WIPTER_EMAIL
  read -rsp "Wipter password (optional): " WIPTER_PASSWORD; echo
  read -rp "Honeygain email (optional): " HONEYGAIN_EMAIL
  read -rsp "Honeygain password (optional): " HONEYGAIN_PASSWORD; echo
}

run_script() {
  local script="$1"; shift
  sudo EXPRESSVPN_ACTIVATION_KEY="$EXPRESSVPN_ACTIVATION_KEY" INSTANCE_COUNT="$INSTANCE_COUNT" REGIONS_RAW="$REGIONS_RAW" "$@" bash "$script" &
  PIDS+=("$!")
}

run_earnapp() { run_script "$EARNAPP_SCRIPT" BASE_NS=earnns VETH_PREFIX=earn WORKDIR=/tmp/earnapp_multi; }
run_traff() { [[ -n "$TRAFF_TOKEN" ]] || { echo "Traff token required"; return; }; run_script "$TRAFF_SCRIPT" BASE_NS=traffns VETH_PREFIX=traff WORKDIR=/tmp/traff_multi APP_PROFILE=traff APP_TOKEN="$TRAFF_TOKEN"; }
run_packetstream() { [[ -n "$PS_TOKEN" ]] || { echo "PacketStream token required"; return; }; run_script "$TRAFF_SCRIPT" BASE_NS=psns VETH_PREFIX=ps WORKDIR=/tmp/ps_multi APP_PROFILE=packetstream APP_TOKEN="$PS_TOKEN"; }
run_castar() { [[ -n "$CASTAR_KEY" ]] || { echo "Castar key required"; return; }; run_script "$CASTAR_SCRIPT" BASE_NS=castarns VETH_PREFIX=castar WORKDIR=/tmp/castar_multi CASTAR_KEY="$CASTAR_KEY"; }
run_urnetwork() { run_script "$UR_SCRIPT" BASE_NS=urns VETH_PREFIX=ur WORKDIR=/tmp/ur_multi; }
run_wipter() { [[ -n "$WIPTER_EMAIL" && -n "$WIPTER_PASSWORD" ]] || { echo "Wipter creds required"; return; }; run_script "$WIPTER_SCRIPT" BASE_NS=wipterns VETH_PREFIX=wipter WORKDIR=/tmp/wipter_multi WIPTER_EMAIL="$WIPTER_EMAIL" WIPTER_PASSWORD="$WIPTER_PASSWORD"; }
run_honeygain() { [[ -n "$HONEYGAIN_EMAIL" && -n "$HONEYGAIN_PASSWORD" ]] || { echo "Honeygain creds required"; return; }; run_script "$HONEYGAIN_SCRIPT" BASE_NS=honeyns VETH_PREFIX=honey WORKDIR=/tmp/honeygain_multi HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL" HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD"; }
run_mysterium() { run_script "$MYSTERIUM_SCRIPT" BASE_NS=mysterns VETH_PREFIX=myster WORKDIR=/tmp/mysterium_multi; }

cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup INT TERM

menu() {
  echo "1) EarnApp"
  echo "2) Traff"
  echo "3) PacketStream"
  echo "4) UrNetwork"
  echo "5) Castar"
  echo "6) Honeygain"
  echo "7) Wipter"
  echo "8) Mysterium"
  echo "9) Run ALL"
  echo "I) Install Mysterium"
  echo "0) Exit"
}

ask_inputs
while true; do
  menu
  read -rp "Select: " opt
  case "$opt" in
    1) run_earnapp; wait ;;
    2) run_traff; wait ;;
    3) run_packetstream; wait ;;
    4) run_urnetwork; wait ;;
    5) run_castar; wait ;;
    6) run_honeygain; wait ;;
    7) run_wipter; wait ;;
    8) run_mysterium; wait ;;
    9) run_earnapp; run_traff; run_packetstream; run_urnetwork; run_castar; run_honeygain; run_wipter; run_mysterium; wait ;;
    I|i) sudo bash "$MYST_INSTALL_SCRIPT" ;;
    0) exit 0 ;;
    *) echo "Invalid" ;;
  esac
done
