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
costa-rica thailand greece france-strasbourg france-paris-1 france-alsace france-marseille france-paris-2
israel iceland singapore-cbd singapore-jurong singapore-marina-bay taiwan-3 south-africa switzerland switzerland-2
bulgaria malaysia indonesia new-zealand hong-kong-2 hong-kong-1 bahamas vietnam croatia liechtenstein luxembourg moldova
slovenia latvia cyprus chile albania slovakia uzbekistan isle-of-man estonia colombia mexico kazakhstan malta georgia
mongolia algeria uruguay guatemala peru venezuela ecuador serbia north-macedonia bosnia-and-herzegovina uk-midlands
uk-east-london uk-tottenham uk-london uk-docklands uk-wembley 'india-(via-uk)' 'india-(via-singapore)'
australia-melbourne australia-sydney-2 australia-brisbane australia-perth australia-woolloomooloo australia-sydney australia-adelaide
italy-milan italy-cosenza italy-naples netherlands-rotterdam netherlands-the-hague netherlands-amsterdam brazil-2 brazil
philippines canada-toronto-2 canada-vancouver canada-montreal canada-toronto macau cambodia kenya andorra armenia belarus
monaco jersey montenegro bangladesh bhutan brunei laos myanmar nepal pakistan sri-lanka panama sweden-2 sweden austria
germany-nuremberg germany-frankfurt-1 germany-frankfurt-3 spain-barcelona spain-madrid spain-barcelona-2 japan-yokohama
japan-tokyo japan-shibuya japan-osaka bolivia guam ghana dominican-republic jamaica puerto-rico bermuda trinidad-and-tobago
cayman-islands cuba honduras lebanon morocco united-arab-emirates azerbaijan portugal poland ireland finland lithuania
czech-republic south-korea-2 denmark egypt belgium romania ukraine argentina turkey norway hungary
)

require_root_and_tools() {
  [[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }
  command -v ip >/dev/null 2>&1 || { echo "ip command missing"; exit 1; }
  [[ -x ./app/expressvpn/start.sh ]] || { echo "Missing ./app/expressvpn/start.sh"; exit 1; }
  [[ -x ./app/expressvpn/bin/expressvpnctl ]] || { echo "Missing ./app/expressvpn/bin/expressvpnctl"; exit 1; }
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
}

calc_octets() { local idx="$1"; echo $(( (idx-1)/254+1 )) $(( (idx-1)%254+1 )); }

create_ns_with_veth() {
  local ns="$1" idx="$2" vprefix="$3"
  local b c; read -r b c <<<"$(calc_octets "$idx")"
  local host_if="${vprefix}${idx}h"; local ns_if="${vprefix}${idx}n"
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
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"/etc/netns/$ns/resolv.conf"
  ip netns exec "$ns" groupadd -f expressvpn >/dev/null 2>&1 || true
}

prompt_vpn_inputs() {
  read -rsp "Enter ExpressVPN activation code (CODE): " CODE
  echo
  [[ -n "${CODE:-}" ]] || { echo "Activation code required"; exit 1; }
  read -rp "How many instances to run? " INSTANCE_COUNT
  [[ "${INSTANCE_COUNT:-}" =~ ^[0-9]+$ ]] && (( INSTANCE_COUNT > 0 )) || { echo "Invalid instance count"; exit 1; }
}

region_for_index() {
  local idx0="$1"
  echo "${REGIONS[$(( idx0 % ${#REGIONS[@]} ))]}"
}

start_expressvpn_for_ns() {
  local ns="$1" idx="$2" region="$3" workdir="$4" repo_dir="$5"
  local logf="$workdir/expressvpn_${idx}.log" pidf="$workdir/expressvpn_${idx}.pid"
  mkdir -p "$workdir/$ns/home"
  ip netns exec "$ns" bash -lc "
    cd '$repo_dir'
    export PATH='$repo_dir/app/expressvpn/bin':\$PATH
    export HOME='$workdir/$ns/home'
    export XDG_RUNTIME_DIR='$workdir/$ns/runtime'
    mkdir -p '$workdir/$ns/runtime'
    export CODE='$CODE'
    export SERVER='$region'
    nohup ./app/expressvpn/start.sh >'$logf' 2>&1 &
    echo \$! > '$pidf'
  "
  ip netns exec "$ns" bash -lc 'for i in {1..90}; do ip link show tun0 >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1' || {
    echo "[$idx] expressvpn did not create tun0 (region=$region). Check $logf"
    return 1
  }
}

cleanup_namespaces() {
  local base_ns="$1" workdir="$2"
  for f in "$workdir"/*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${base_ns}[0-9]+$" || true); do
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}
