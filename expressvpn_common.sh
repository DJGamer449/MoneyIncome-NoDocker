#!/usr/bin/env bash

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
india-(via-uk) india-(via-singapore)
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

prompt_vpn_settings() {
  local protocol_default="auto"
  if [[ -z "${ACTIVATION_CODE:-}" ]]; then
    read -rsp "Enter ExpressVPN activation key: " ACTIVATION_CODE
    echo
  fi
  if [[ -z "${INSTANCE_COUNT:-}" ]]; then
    read -rp "How many instances do you want to run? " INSTANCE_COUNT
  fi
  if [[ -z "${VPN_PROTOCOL:-}" ]]; then
    read -rp "Protocol for all instances [default: ${protocol_default}]: " VPN_PROTOCOL
    VPN_PROTOCOL="${VPN_PROTOCOL:-$protocol_default}"
  fi

  INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
  if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || (( INSTANCE_COUNT < 1 )); then
    echo "Invalid instance count: $INSTANCE_COUNT"
    exit 1
  fi

  SELECTED_REGIONS=()
  local i default_idx default_region entered
  for (( i=1; i<=INSTANCE_COUNT; i++ )); do
    default_idx=$(( (i-1) % ${#REGIONS[@]} ))
    default_region="${REGIONS[$default_idx]}"
    read -rp "Region for instance ${i} [default: ${default_region}]: " entered
    SELECTED_REGIONS+=("${entered:-$default_region}")
  done
}

ensure_expressvpn_binaries() {
  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$base_dir/app/expressvpn/bin}"
  EXPRESSVPN_DAEMON="${EXPRESSVPN_DAEMON:-$EXPRESSVPN_BIN_DIR/expressvpn-daemon}"
  EXPRESSVPNCTL="${EXPRESSVPNCTL:-$EXPRESSVPN_BIN_DIR/expressvpnctl}"
  [[ -x "$EXPRESSVPN_DAEMON" ]] || { echo "Missing executable: $EXPRESSVPN_DAEMON"; exit 1; }
  [[ -x "$EXPRESSVPNCTL" ]] || { echo "Missing executable: $EXPRESSVPNCTL"; exit 1; }
}

start_expressvpn_in_ns() {
  local ns="$1" idx="$2" region="$3" workdir="$4"
  local vpn_root="$workdir/expressvpn_${idx}"
  mkdir -p "$vpn_root/home" "$vpn_root/config" "$vpn_root/data" "$vpn_root/runtime" "$vpn_root/log"

  ip netns exec "$ns" groupadd -f expressvpn >/dev/null 2>&1 || true
  ip netns exec "$ns" env \
    HOME="$vpn_root/home" \
    XDG_CONFIG_HOME="$vpn_root/config" \
    XDG_DATA_HOME="$vpn_root/data" \
    XDG_RUNTIME_DIR="$vpn_root/runtime" \
    bash -lc "
      '$EXPRESSVPN_DAEMON' >'$vpn_root/log/daemon.log' 2>&1 &
      sleep 2
      '$EXPRESSVPNCTL' background enable
      '$EXPRESSVPNCTL' set networklock true
      '$EXPRESSVPNCTL' set region '$region'
      '$EXPRESSVPNCTL' set protocol '$VPN_PROTOCOL'
      '$EXPRESSVPNCTL' login <(echo '$ACTIVATION_CODE')
      '$EXPRESSVPNCTL' connect
    "
}
