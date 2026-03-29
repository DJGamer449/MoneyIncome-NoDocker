#!/usr/bin/env bash
set -euo pipefail

EVPN_BIN_DIR="${EVPN_BIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app/expressvpn/bin}"
EVPN_DAEMON="${EVPN_DAEMON:-$EVPN_BIN_DIR/expressvpn-daemon}"
EVPN_CTL="${EVPN_CTL:-$EVPN_BIN_DIR/expressvpnctl}"

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
  singapore-cbd singapore-jurong singapore-marina-bay taiwan-3 south-africa switzerland switzerland-2 bulgaria malaysia
  indonesia new-zealand hong-kong-2 hong-kong-1 bahamas vietnam croatia liechtenstein luxembourg moldova slovenia latvia
  cyprus chile albania slovakia uzbekistan isle-of-man estonia colombia mexico kazakhstan malta georgia mongolia algeria
  uruguay guatemala peru venezuela ecuador serbia north-macedonia bosnia-and-herzegovina uk-midlands uk-east-london
  uk-tottenham uk-london uk-docklands uk-wembley 'india-(via-uk)' 'india-(via-singapore)' australia-melbourne australia-sydney-2
  australia-brisbane australia-perth australia-woolloomooloo australia-sydney australia-adelaide italy-milan italy-cosenza
  italy-naples netherlands-rotterdam netherlands-the-hague netherlands-amsterdam brazil-2 brazil philippines canada-toronto-2
  canada-vancouver canada-montreal canada-toronto macau cambodia kenya andorra armenia belarus monaco jersey montenegro
  bangladesh bhutan brunei laos myanmar nepal pakistan sri-lanka panama sweden-2 sweden austria germany-nuremberg
  germany-frankfurt-1 germany-frankfurt-3 spain-barcelona spain-madrid spain-barcelona-2 japan-yokohama japan-tokyo
  japan-shibuya japan-osaka bolivia guam ghana dominican-republic jamaica puerto-rico bermuda trinidad-and-tobago cayman-islands
  cuba honduras lebanon morocco united-arab-emirates azerbaijan portugal poland ireland finland lithuania czech-republic
  south-korea-2 denmark egypt belgium romania ukraine argentina turkey norway hungary
)

require_root_and_tools() {
  [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
  [[ -x "$EVPN_DAEMON" ]] || { echo "expressvpn-daemon not found at $EVPN_DAEMON"; exit 1; }
  [[ -x "$EVPN_CTL" ]] || { echo "expressvpnctl not found at $EVPN_CTL"; exit 1; }
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx-1) / 254 + 1 ))
  local c=$(( (idx-1) % 254 + 1 ))
  echo "$b" "$c"
}

create_ns_with_veth() {
  local idx="$1" ns="$2" veth_prefix="$3"
  local host_if="${veth_prefix}${idx}h" ns_if="${veth_prefix}${idx}n"
  local b c; read -r b c <<<"$(calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true
  ip link show "$host_if" >/dev/null 2>&1 || ip link add "$host_if" type veth peer name "$ns_if"
  ip link set "$ns_if" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$ns_if"

  mkdir -p "/etc/netns/$ns"
  cat > "/etc/netns/$ns/resolv.conf" <<DNS
nameserver 1.1.1.1
nameserver 8.8.8.8
DNS
}

region_for_index() {
  local idx="$1"
  local n="${#REGIONS[@]}"
  echo "${REGIONS[$(((idx-1)%n))]}"
}

configure_expressvpn_in_ns() {
  local idx="$1" ns="$2" workdir="$3" activation_code="$4" protocol="$5" region="$6"
  local inst_dir="$workdir/inst_${idx}"
  mkdir -p "$inst_dir/home" "$inst_dir/run" "$inst_dir/config" "$inst_dir/state"

  ip netns exec "$ns" bash -lc "
    set -euo pipefail
    export HOME='$inst_dir/home'
    export XDG_RUNTIME_DIR='$inst_dir/run'
    export XDG_CONFIG_HOME='$inst_dir/config'
    export XDG_STATE_HOME='$inst_dir/state'
    mkdir -p \"\$HOME\" \"\$XDG_RUNTIME_DIR\" \"\$XDG_CONFIG_HOME\" \"\$XDG_STATE_HOME\"

    getent group expressvpn >/dev/null 2>&1 || groupadd -f expressvpn || true

    nohup '$EVPN_DAEMON' >'$workdir/expressvpn_daemon_${idx}.log' 2>&1 &
    sleep 2
    '$EVPN_CTL' background enable
    '$EVPN_CTL' set networklock true
    '$EVPN_CTL' set auto_connect true
    '$EVPN_CTL' set region '$region'
    '$EVPN_CTL' set protocol '$protocol'
    '$EVPN_CTL' login <(echo '$activation_code')
    '$EVPN_CTL' connect '$region'
  "
}

cleanup_ns_batch() {
  local base_ns="$1" veth_prefix="$2" workdir="$3"
  for f in "$workdir"/app_*.pid "$workdir"/expressvpn-daemon_*.pid; do
    [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true
  done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${base_ns}[0-9]+$" || true); do
    local idx="${ns#${base_ns}}"
    ip link del "${veth_prefix}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}
