#!/usr/bin/env bash
set -euo pipefail

EXPRESSVPN_SRC_DIR="${EXPRESSVPN_SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$EXPRESSVPN_SRC_DIR/bin}"
EXPRESSVPN_SCRIPT_SRC="${EXPRESSVPN_SCRIPT_SRC:-$EXPRESSVPN_SRC_DIR/script}"
EXPRESSVPN_SERVICE_SRC="${EXPRESSVPN_SERVICE_SRC:-$EXPRESSVPN_SRC_DIR/expressvpn-service}"

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
  "india-(via-uk)" "india-(via-singapore)"
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

next_region() {
  local idx="$1"
  local n=${#REGIONS[@]}
  echo "${REGIONS[$(( (idx - 1) % n ))]}"
}

prepare_expressvpn_fs() {
  local base_dir="$1"
  mkdir -p "$base_dir/bin" "$base_dir/etc/init.d" "$base_dir/var" "$base_dir/run"
  cp -a "$EXPRESSVPN_BIN_DIR/." "$base_dir/bin/"
  cp -f "$EXPRESSVPN_SERVICE_SRC" "$base_dir/etc/init.d/expressvpn-service"
  chmod +x "$base_dir/etc/init.d/expressvpn-service" "$base_dir/bin/expressvpn-daemon" "$base_dir/bin/expressvpnctl" 2>/dev/null || true
}

start_expressvpn_in_namespace() {
  local ns="$1" idx="$2" activation_key="$3" root_base="$4"
  local instance_dir="$root_base/instance_${idx}"
  local region
  region="$(next_region "$idx")"

  prepare_expressvpn_fs "$instance_dir"
  mkdir -p "/etc/netns/$ns"
  cp -f /etc/resolv.conf "/etc/netns/$ns/resolv.conf" || true

  ip netns exec "$ns" unshare -m bash -lc "
    set -e
    mount --make-rprivate /
    mkdir -p /opt/expressvpn /expressvpn /etc/init.d /var/lib/expressvpn /var/run/expressvpn /tmp/expressvpn
    mount --bind '$instance_dir' /opt/expressvpn
    mount --bind '$EXPRESSVPN_SCRIPT_SRC' /expressvpn
    mount --bind /opt/expressvpn/etc/init.d /etc/init.d
    mount --bind /opt/expressvpn/var /var/lib/expressvpn
    mount --bind /opt/expressvpn/run /var/run/expressvpn
    export PATH=/opt/expressvpn/bin:\$PATH
    /opt/expressvpn/bin/expressvpn-daemon >/tmp/expressvpn/daemon.log 2>&1 &
    sleep 3
    printf '%s' '$activation_key' >/tmp/expressvpn/activation.key
    expressvpnctl login /tmp/expressvpn/activation.key >/tmp/expressvpn/login.log 2>&1 || true
    expressvpnctl connect '$region' >/tmp/expressvpn/connect.log 2>&1
    for i in {1..60}; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; done
  "

  echo "$region"
}
