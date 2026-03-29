#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$BASE_DIR/app/expressvpn/bin}"
EXPRESSVPN_CTL="${EXPRESSVPN_CTL:-$EXPRESSVPN_BIN_DIR/expressvpnctl}"
EXPRESSVPN_DAEMON="${EXPRESSVPN_DAEMON:-$EXPRESSVPN_BIN_DIR/expressvpn-daemon}"
HOST_IF="${HOST_IF:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}"
HOST_IF="${HOST_IF:-eth0}"
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"

EXPRESSVPN_REGIONS=(
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

require_expressvpn_prereqs() {
  [[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
  [[ -x "$EXPRESSVPN_CTL" ]] || { echo "Missing expressvpnctl at $EXPRESSVPN_CTL"; exit 1; }
  [[ -x "$EXPRESSVPN_DAEMON" ]] || { echo "Missing expressvpn-daemon at $EXPRESSVPN_DAEMON"; exit 1; }
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx-1) / 254 + 1 ))
  local c=$(( (idx-1) % 254 + 1 ))
  echo "$b" "$c"
}

region_for_index() {
  local idx="$1"
  local count="${#EXPRESSVPN_REGIONS[@]}"
  echo "${EXPRESSVPN_REGIONS[$(( (idx-1) % count ))]}"
}

create_netns_with_veth() {
  local ns="$1" idx="$2" prefix="$3"
  local b c host_if ns_if subnet
  read -r b c < <(calc_octets "$idx")
  host_if="${prefix}h${idx}"
  ns_if="${prefix}n${idx}"
  subnet="10.${b}.${c}.0/24"

  ip netns add "$ns" 2>/dev/null || true
  ip link add "$host_if" type veth peer name "$ns_if" 2>/dev/null || true
  ip link set "$ns_if" netns "$ns" 2>/dev/null || true
  ip addr replace "10.${b}.${c}.1/24" dev "$host_if"
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr replace "10.${b}.${c}.2/24" dev "$ns_if"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$ns_if"

  mkdir -p "/etc/netns/$ns"
  if [[ "$FORCE_NS_DNS" == "1" ]]; then
    : > "/etc/netns/$ns/resolv.conf"
    for dns in $NS_DNS_LIST; do
      echo "nameserver $dns" >> "/etc/netns/$ns/resolv.conf"
    done
  fi

  iptables -t nat -C POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
}

start_expressvpn_in_ns() {
  local ns="$1" idx="$2" protocol="$3" activation="$4" workdir="$5"
  local region ns_state
  region="$(region_for_index "$idx")"
  ns_state="$workdir/${ns}_expressvpn"
  mkdir -p "$ns_state/home" "$ns_state/runtime" "$ns_state/config"

  ip netns exec "$ns" env \
    EXPRESSVPN_BIN_DIR="$EXPRESSVPN_BIN_DIR" \
    EXPRESSVPN_PROTOCOL="$protocol" \
    EXPRESSVPN_ACTIVATION="$activation" \
    EXPRESSVPN_REGION="$region" \
    EXPRESSVPN_STATE="$ns_state" \
    bash -lc '
      set -e
      groupadd -f expressvpn || true
      export PATH="$EXPRESSVPN_BIN_DIR:$PATH"
      export HOME="$EXPRESSVPN_STATE/home"
      export XDG_RUNTIME_DIR="$EXPRESSVPN_STATE/runtime"
      export XDG_CONFIG_HOME="$EXPRESSVPN_STATE/config"
      pkill -f expressvpn-daemon >/dev/null 2>&1 || true
      nohup expressvpn-daemon >"$EXPRESSVPN_STATE/daemon.log" 2>&1 &
      sleep 2
      expressvpnctl background enable
      expressvpnctl set networklock true
      expressvpnctl set region "$EXPRESSVPN_REGION"
      expressvpnctl set protocol "$EXPRESSVPN_PROTOCOL"
      expressvpnctl login <(echo "$EXPRESSVPN_ACTIVATION") || true
      expressvpnctl connect
    '
  echo "[$idx] ExpressVPN connected in $ns (region=$region)"
}

cleanup_ns_prefix() {
  local base_ns="$1"
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${base_ns}[0-9]+$" || true); do
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}
