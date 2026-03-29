#!/usr/bin/env bash
set -euo pipefail

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

install_expressvpn_files() {
  mkdir -p /opt/expressvpn
  cp -r ./app/expressvpn/* /opt/expressvpn/
  install -m 0755 ./app/expressvpn/bin/expressvpnctl /usr/local/bin/expressvpnctl
}

setup_ns() {
  local ns="$1" idx="$2" prefix="$3"
  local host_if="${prefix}${idx}h" ns_if="${prefix}${idx}n"
  ip netns add "$ns" 2>/dev/null || true
  ip link add "$host_if" type veth peer name "$ns_if" 2>/dev/null || true
  ip link set "$ns_if" netns "$ns"
  ip addr add "10.210.${idx}.1/24" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr add "10.210.${idx}.2/24" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.210.${idx}.1" dev "$ns_if"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  iptables -t nat -C POSTROUTING -s "10.210.${idx}.0/24" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "10.210.${idx}.0/24" -j MASQUERADE
  groupadd -f expressvpn
  ip netns exec "$ns" groupadd -f expressvpn || true
}

start_expressvpn_in_ns() {
  local ns="$1" code="$2" region="$3" idx="$4" logf="$5"
  ip netns exec "$ns" bash -lc "export CODE='$code'; export SERVER='$region'; export HOME='/tmp/expressvpn-home-$idx'; mkdir -p \"\$HOME\"; /opt/expressvpn/start.sh >'$logf' 2>&1 &"
  sleep 2
}

ask_expressvpn_inputs() {
  local code_var="$1" count_var="$2"
  read -rp "Enter ExpressVPN activation key: " "$code_var"
  read -rp "How many instances do you want to run? " "$count_var"
  eval "[[ -n \"\${$code_var}\" ]]" || { echo "Activation key is required."; exit 1; }
  eval "[[ \"\${$count_var}\" =~ ^[0-9]+$ && \"\${$count_var}\" -gt 0 ]]" || { echo "Instance count must be > 0."; exit 1; }
}

region_for_idx() {
  local idx="$1"
  local n=${#REGIONS[@]}
  echo "${REGIONS[$(((idx-1)%n))]}"
}
