#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-app}"
APP_CMD_STR="${APP_CMD_STR:-}"
BASE_NS="${BASE_NS:-xvpns}"
VETH_PREFIX="${VETH_PREFIX:-xveth}"
WORKDIR="${WORKDIR:-/tmp/expressvpn_multi}"
INSTANCES="${INSTANCES:-}"
CODE="${CODE:-}"
PROTOCOL="${PROTOCOL:-lightwayudp}"
EXPRESSVPNCTL="${EXPRESSVPNCTL:-$(cd "$(dirname "$0")" && pwd)/app/expressvpn/bin/expressvpnctl}"
EXPRESSVPN_DAEMON="${EXPRESSVPN_DAEMON:-$(cd "$(dirname "$0")" && pwd)/app/expressvpn/bin/expressvpn-daemon}"

mkdir -p "$WORKDIR"

DEFAULT_REGIONS=(
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

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
  [[ -x "$EXPRESSVPNCTL" ]] || command -v expressvpnctl >/dev/null 2>&1 || { echo "expressvpnctl not found at $EXPRESSVPNCTL"; exit 1; }
  [[ -x "$EXPRESSVPN_DAEMON" ]] || command -v expressvpn-daemon >/dev/null 2>&1 || { echo "expressvpn-daemon not found at $EXPRESSVPN_DAEMON"; exit 1; }
}
ctl_cmd() {
  if [[ -x "$EXPRESSVPNCTL" ]]; then
    printf '%q' "$EXPRESSVPNCTL"
  else
    printf '%s' "expressvpnctl"
  fi
}
daemon_cmd() {
  if [[ -x "$EXPRESSVPN_DAEMON" ]]; then
    printf '%q' "$EXPRESSVPN_DAEMON"
  else
    printf '%s' "expressvpn-daemon"
  fi
}

ask_inputs() {
  if [[ -z "$CODE" ]]; then
    read -rp "Enter ExpressVPN activation key: " CODE
  fi
  while [[ -z "${INSTANCES}" || ! "${INSTANCES}" =~ ^[1-9][0-9]*$ ]]; do
    read -rp "How many instances for ${APP_NAME}? " INSTANCES
  done
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

create_ns_with_veth() {
  local idx="${1:-}"
  [[ -n "$idx" ]] || { echo "create_ns_with_veth: missing instance index" >&2; return 1; }
  local ns="${BASE_NS}${idx}" host_if="${VETH_PREFIX}${idx}h" ns_if="${VETH_PREFIX}${idx}n"
  local b=$(( (idx-1)/254 + 1 )) c=$(( (idx-1)%254 + 1 ))
  ip netns add "$ns" 2>/dev/null || true
  ip link show "$host_if" >/dev/null 2>&1 || ip link add "$host_if" type veth peer name "$ns_if"
  ip link set "$ns_if" netns "$ns" 2>/dev/null || true
  ip addr add "10.${b}.${c}.1/24" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$ns_if"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  echo "$ns"
}

start_instance_supervisor() {
  local ns="$1" idx="$2" region="$3" ctl daemon
  ctl="$(ctl_cmd)"
  daemon="$(daemon_cmd)"
  local inst_home="$WORKDIR/inst_${idx}"
  local inst_run="$inst_home/var_run_expressvpn"
  local inst_lib="$inst_home/var_lib_expressvpn"
  local app_cmd_b64

  mkdir -p "$inst_home"
  mkdir -p "$inst_run" "$inst_lib"
  printf '%s' "$CODE" >"$inst_home/token"
  app_cmd_b64="$(printf '%s' "$APP_CMD_STR" | base64 -w0)"

  ip netns exec "$ns" unshare -m env \
    INST_HOME="$inst_home" \
    INST_RUN="$inst_run" \
    INST_LIB="$inst_lib" \
    APP_CMD_B64="$app_cmd_b64" \
    REGION="$region" \
    PROTOCOL="$PROTOCOL" \
    ACTIVATION_CODE="$CODE" \
    CTL="$ctl" \
    DAEMON="$daemon" \
    INDEX="$idx" \
    bash -lc '
      set -euo pipefail
      trap "kill ${daemon_pid:-0} ${app_pid:-0} 2>/dev/null || true; umount /var/run/expressvpn 2>/dev/null || true; umount /var/lib/expressvpn 2>/dev/null || true" EXIT
      groupadd -f expressvpn >/dev/null 2>&1 || true
      mkdir -p /var/run/expressvpn /var/lib/expressvpn "$INST_HOME"
      mount --bind "$INST_RUN" /var/run/expressvpn
      mount --bind "$INST_LIB" /var/lib/expressvpn
      export HOME="$INST_HOME"
      export XDG_RUNTIME_DIR="$INST_HOME/runtime"
      mkdir -p "$XDG_RUNTIME_DIR"

      "$DAEMON" >"$INST_HOME/daemon.log" 2>&1 &
      daemon_pid=$!
      sleep 2

      "$CTL" background enable >"$INST_HOME/background.log" 2>&1 || true
      "$CTL" set networklock true >"$INST_HOME/networklock.log" 2>&1 || true
      "$CTL" set auto_connect true >"$INST_HOME/autoconnect.log" 2>&1 || true
      "$CTL" set region "$REGION" >"$INST_HOME/region.log" 2>&1 || true
      "$CTL" set protocol "$PROTOCOL" >"$INST_HOME/protocol.log" 2>&1 || true
      "$CTL" login <(echo "$ACTIVATION_CODE") >"$INST_HOME/login.log" 2>&1 || true
      "$CTL" connect >"$INST_HOME/connect.log" 2>&1
      "$CTL" status >"$INST_HOME/status.log" 2>&1 || true

      cd "'"$(pwd)"'"
      app_cmd="$(printf "%s" "$APP_CMD_B64" | base64 -d)"
      bash -lc "$app_cmd" >"'"$WORKDIR"'/app_${INDEX}.log" 2>&1 &
      app_pid=$!
      echo "$app_pid" >"'"$WORKDIR"'/app_${INDEX}.pid"
      wait "$app_pid"
    ' &
  echo $! >"$WORKDIR/supervisor_${idx}.pid"
}

cleanup() {
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for f in "$WORKDIR"/supervisor_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#${BASE_NS}}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
}
trap cleanup EXIT

main() {
  require_root
  [[ -n "$APP_CMD_STR" ]] || { echo "APP_CMD_STR is required"; exit 1; }
  ask_inputs
  setup_nat_once

  local -a regions=("${DEFAULT_REGIONS[@]}")
  if [[ -n "${REGIONS:-}" ]]; then
    read -r -a regions <<<"${REGIONS}"
  fi

  for ((i=1; i<=INSTANCES; i++)); do
    local ns region
    ns="$(create_ns_with_veth "$i")"
    region="${regions[$(( (i-1) % ${#regions[@]} ))]}"
    echo "[$i] ${APP_NAME}: namespace=$ns region=$region"
    start_instance_supervisor "$ns" "$i" "$region"
  done

  echo "Started ${INSTANCES} ${APP_NAME} instance(s) with ExpressVPN."
  wait
}

main "$@"
