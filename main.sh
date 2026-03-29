#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

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
"israel" "iceland" "singapore-cbd" "singapore-jurong" "singapore-marina-bay" "taiwan-3" "south-africa"
"switzerland" "switzerland-2" "bulgaria" "malaysia" "indonesia" "new-zealand" "hong-kong-2" "hong-kong-1" "bahamas" "vietnam"
"croatia" "liechtenstein" "luxembourg" "moldova" "slovenia" "latvia" "cyprus" "chile" "albania" "slovakia" "uzbekistan" "isle-of-man" "estonia"
"colombia" "mexico" "kazakhstan" "malta" "georgia" "mongolia" "algeria" "uruguay" "guatemala" "peru" "venezuela" "ecuador"
"serbia" "north-macedonia" "bosnia-and-herzegovina" "uk-midlands" "uk-east-london" "uk-tottenham" "uk-london" "uk-docklands" "uk-wembley"
"india-(via-uk)" "india-(via-singapore)" "australia-melbourne" "australia-sydney-2" "australia-brisbane" "australia-perth" "australia-woolloomooloo" "australia-sydney" "australia-adelaide"
"italy-milan" "italy-cosenza" "italy-naples" "netherlands-rotterdam" "netherlands-the-hague" "netherlands-amsterdam" "brazil-2" "brazil" "philippines"
"canada-toronto-2" "canada-vancouver" "canada-montreal" "canada-toronto" "macau" "cambodia" "kenya" "andorra" "armenia" "belarus" "monaco" "jersey" "montenegro"
"bangladesh" "bhutan" "brunei" "laos" "myanmar" "nepal" "pakistan" "sri-lanka" "panama" "sweden-2" "sweden" "austria"
"germany-nuremberg" "germany-frankfurt-1" "germany-frankfurt-3" "spain-barcelona" "spain-madrid" "spain-barcelona-2"
"japan-yokohama" "japan-tokyo" "japan-shibuya" "japan-osaka" "bolivia" "guam" "ghana" "dominican-republic" "jamaica" "puerto-rico" "bermuda" "trinidad-and-tobago" "cayman-islands" "cuba" "honduras"
"lebanon" "morocco" "united-arab-emirates" "azerbaijan" "portugal" "poland" "ireland" "finland" "lithuania" "czech-republic"
"south-korea-2" "denmark" "egypt" "belgium" "romania" "ukraine" "argentina" "turkey" "norway" "hungary"
)

TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
HONEYGAIN_EMAIL=""
HONEYGAIN_PASSWORD=""
EXPRESSVPN_ACTIVATION_CODE=""
INSTANCE_COUNT=1
REGIONS_CSV=""

regions_csv_from_count() {
  local count="$1" out=() i idx
  for ((i=1; i<=count; i++)); do
    idx=$(( (i-1) % ${#REGIONS[@]} ))
    out+=("${REGIONS[$idx]}")
  done
  IFS=','; echo "${out[*]}"
}

ask_global_inputs() {
  read -rp "ExpressVPN activation code: " EXPRESSVPN_ACTIVATION_CODE
  read -rp "How many instances per app? " INSTANCE_COUNT
  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "Invalid instance count"; exit 1; }

  REGIONS_CSV="$(regions_csv_from_count "$INSTANCE_COUNT")"
  echo "Assigned regions (cycled):"
  tr ',' '\n' <<<"$REGIONS_CSV" | nl -ba

  read -rp "Traff token (optional): " TRAFF_TOKEN
  read -rp "PacketStream CID (optional): " PS_TOKEN
  read -rp "Castar key (optional): " CASTAR_KEY
  read -rp "Honeygain email (optional): " HONEYGAIN_EMAIL
  read -rsp "Honeygain password (optional): " HONEYGAIN_PASSWORD
  echo
}

run_app() {
  local script="$1"
  shift
  sudo env \
    EXPRESSVPN_ACTIVATION_CODE="$EXPRESSVPN_ACTIVATION_CODE" \
    INSTANCE_COUNT="$INSTANCE_COUNT" \
    REGIONS_CSV="$REGIONS_CSV" \
    "$@" \
    bash "$BASE_DIR/$script"
}

menu() {
  echo
  echo "===== EXPRESSVPN ISOLATED NETNS MANAGER ====="
  echo "1) EarnApp"
  echo "2) Traff"
  echo "3) PacketStream"
  echo "4) UrNetwork"
  echo "5) Castar"
  echo "6) Honeygain"
  echo "7) Wipter"
  echo "8) Mysterium"
  echo "9) Run ALL"
  echo "0) Exit"
}

ask_global_inputs

while true; do
  menu
  read -rp "Select option: " opt
  case "$opt" in
    1) run_app "direct_earnapp.sh" ;;
    2) run_app "direct_traff.sh" TRAFF_TOKEN="$TRAFF_TOKEN" ;;
    3) run_app "direct_traff.sh" TRAFF_TOKEN="$PS_TOKEN" ;;
    4) run_app "direct_urnetwork.sh" ;;
    5) run_app "direct_castar.sh" CASTAR_KEY="$CASTAR_KEY" ;;
    6) run_app "direct_honeygain.sh" HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL" HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD" ;;
    7) run_app "direct_wipter.sh" ;;
    8) run_app "direct_mysterium.sh" ;;
    9)
      run_app "direct_earnapp.sh"
      run_app "direct_traff.sh" TRAFF_TOKEN="$TRAFF_TOKEN"
      run_app "direct_traff.sh" TRAFF_TOKEN="$PS_TOKEN"
      run_app "direct_urnetwork.sh"
      run_app "direct_castar.sh" CASTAR_KEY="$CASTAR_KEY"
      run_app "direct_honeygain.sh" HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL" HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD"
      run_app "direct_wipter.sh"
      run_app "direct_mysterium.sh"
      ;;
    0) exit 0 ;;
    *) echo "Invalid option" ;;
  esac
done
