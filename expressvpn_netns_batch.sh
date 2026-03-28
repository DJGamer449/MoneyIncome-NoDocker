#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPRESSVPN_DIR="${BASE_DIR}/app/expressvpn"
EXPRESSVPNCTL="${EXPRESSVPN_DIR}/expressvpnctl"
STATE_DIR="${BASE_DIR}/.expressvpn-netns"
BATCH_SIZE=50
CONNECT_TIMEOUT=180
PROTOCOL="lightwayudp"
ALLOW_LAN="true"
HOST_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
HOST_IF="${HOST_IF:-eth0}"

mkdir -p "$STATE_DIR"

aliases=(
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
  'india-(via-uk)' 'india-(via-singapore)'

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

usage() {
  cat <<USAGE
Usage:
  $0 start [options]
  $0 stop
  $0 status

Options for start:
  --code <activation_code>   ExpressVPN activation code (or use EXPRESSVPN_CODE env)
  --batch-size <n>           Max instances per batch (default: ${BATCH_SIZE})
  --timeout <seconds>        Wait timeout for each batch to be connected (default: ${CONNECT_TIMEOUT})
  --protocol <name>          Protocol for expressvpnctl set protocol (default: ${PROTOCOL})
  --allow-lan <true|false>   Set allowlan (default: ${ALLOW_LAN})
  --select                   Interactively select one location and only start one namespace
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (required for netns and iptables)."
    exit 1
  fi
}

require_tools() {
  command -v ip >/dev/null 2>&1 || { echo "ip command not found"; exit 1; }
  command -v iptables >/dev/null 2>&1 || { echo "iptables not found"; exit 1; }
  [[ -x "$EXPRESSVPNCTL" ]] || { echo "Missing executable: $EXPRESSVPNCTL"; exit 1; }
}

pick_alias_interactive() {
  echo "Select ExpressVPN location:"
  local i
  for i in "${!aliases[@]}"; do
    printf '  %3d) %s\n' "$((i+1))" "${aliases[$i]}"
  done
  local choice
  read -rp "Enter number: " choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#aliases[@]} )); then
    echo "Invalid selection"
    exit 1
  fi
  SELECTED_ALIAS="${aliases[$((choice-1))]}"
}

create_ns() {
  local idx="$1"
  local ns="expressvpn-${idx}"
  local vh="xv-h-${idx}"
  local vn="xv-n-${idx}"
  local subnet_octet=$((100 + idx))
  local host_ip="10.250.${subnet_octet}.1/24"
  local ns_ip="10.250.${subnet_octet}.2/24"
  local subnet="10.250.${subnet_octet}.0/24"

  ip netns del "$ns" 2>/dev/null || true
  rm -rf "/etc/netns/${ns}" 2>/dev/null || true
  ip link del "$vh" 2>/dev/null || true

  ip netns add "$ns"
  ip link add "$vh" type veth peer name "$vn"
  ip link set "$vn" netns "$ns"
  ip addr add "$host_ip" dev "$vh"
  ip link set "$vh" up

  ip netns exec "$ns" ip addr add "$ns_ip" dev "$vn"
  ip netns exec "$ns" ip link set "$vn" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route replace default via "10.250.${subnet_octet}.1" dev "$vn"

  mkdir -p "/etc/netns/${ns}"
  {
    echo "nameserver 1.1.1.1"
    echo "nameserver 8.8.8.8"
  } > "/etc/netns/${ns}/resolv.conf"

  iptables -t nat -C POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
}

launch_instance() {
  local idx="$1"
  local server="$2"
  local ns="expressvpn-${idx}"
  local log_file="${STATE_DIR}/${ns}.log"

  create_ns "$idx"

  ip netns exec "$ns" env \
    CODE="$CODE" \
    SERVER="$server" \
    PROTOCOL="$PROTOCOL" \
    ALLOW_LAN="$ALLOW_LAN" \
    EXPRESSVPNCTL="$EXPRESSVPNCTL" \
    bash -lc '
      set -euo pipefail
      ctl="$EXPRESSVPNCTL"
      code_file="/tmp/expressvpn-code.txt"
      printf "%s" "$CODE" > "$code_file"

      "$ctl" --timeout 60 login "$code_file" >/dev/null 2>&1 || true
      rm -f "$code_file"

      "$ctl" background enable >/dev/null 2>&1 || true
      "$ctl" set allowlan "$ALLOW_LAN" >/dev/null 2>&1 || true
      "$ctl" set autoconnect false >/dev/null 2>&1 || true
      "$ctl" set protocol "$PROTOCOL" >/dev/null 2>&1 || true
      "$ctl" disconnect >/dev/null 2>&1 || true
      "$ctl" connect "$SERVER"

      while true; do
        sleep 300
      done
    ' >"$log_file" 2>&1 &

  echo "$!" > "${STATE_DIR}/${ns}.pid"
  echo "$server" > "${STATE_DIR}/${ns}.server"
}

is_connected() {
  local ns="$1"
  [[ "$(ip netns exec "$ns" "$EXPRESSVPNCTL" get connectionstate 2>/dev/null || true)" == "Connected" ]]
}

wait_for_batch() {
  local -n batch_ref=$1
  local deadline=$((SECONDS + CONNECT_TIMEOUT))

  while (( SECONDS < deadline )); do
    local pending=0
    local ns
    for ns in "${batch_ref[@]}"; do
      if ! is_connected "$ns"; then
        pending=$((pending + 1))
      fi
    done
    if (( pending == 0 )); then
      return 0
    fi
    sleep 2
  done

  return 1
}

start_all() {
  local targets=()
  if [[ "${SELECT_MODE}" == "1" ]]; then
    pick_alias_interactive
    targets=("$SELECTED_ALIAS")
  else
    targets=("${aliases[@]}")
  fi

  local total="${#targets[@]}"
  echo "Starting ${total} ExpressVPN netns instance(s), batch size=${BATCH_SIZE}"

  local i=0
  while (( i < total )); do
    local batch_ns=()
    local started=0
    while (( i < total && started < BATCH_SIZE )); do
      local idx=$((i + 1))
      local server="${targets[$i]}"
      local ns="expressvpn-${idx}"

      echo "[${idx}/${total}] launch ${ns} -> ${server}"
      launch_instance "$idx" "$server"
      batch_ns+=("$ns")

      started=$((started + 1))
      i=$((i + 1))
      sleep 1
    done

    echo "Waiting for current batch to connect..."
    if wait_for_batch batch_ns; then
      echo "Batch connected."
    else
      echo "Batch connection timeout (${CONNECT_TIMEOUT}s)."
      echo "Check logs: ${STATE_DIR}/expressvpn-*.log"
      exit 1
    fi
  done

  echo "All instances launched and connected."
}

stop_all() {
  local ns
  for ns in $(ip netns list | awk '{print $1}' | grep '^expressvpn-[0-9]\+$' || true); do
    echo "Stopping ${ns}"
    if [[ -f "${STATE_DIR}/${ns}.pid" ]]; then
      kill "$(cat "${STATE_DIR}/${ns}.pid")" 2>/dev/null || true
      rm -f "${STATE_DIR}/${ns}.pid"
    fi

    local idx="${ns#expressvpn-}"
    local vh="xv-h-${idx}"
    local subnet_octet=$((100 + idx))
    local subnet="10.250.${subnet_octet}.0/24"

    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/${ns}" 2>/dev/null || true
    ip link del "$vh" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || true
  done

  echo "Stopped all expressvpn netns instances."
}

status_all() {
  local ns
  for ns in $(ip netns list | awk '{print $1}' | grep '^expressvpn-[0-9]\+$' || true); do
    local state
    state="$(ip netns exec "$ns" "$EXPRESSVPNCTL" get connectionstate 2>/dev/null || echo unknown)"
    local server=""
    [[ -f "${STATE_DIR}/${ns}.server" ]] && server="$(cat "${STATE_DIR}/${ns}.server")"
    echo "${ns}  state=${state}  server=${server}"
  done
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true

  SELECT_MODE=0
  CODE="${EXPRESSVPN_CODE:-}"

  while (($#)); do
    case "$1" in
      --code) CODE="$2"; shift 2 ;;
      --batch-size) BATCH_SIZE="$2"; shift 2 ;;
      --timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
      --protocol) PROTOCOL="$2"; shift 2 ;;
      --allow-lan) ALLOW_LAN="$2"; shift 2 ;;
      --select) SELECT_MODE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done

  require_root
  require_tools

  case "$cmd" in
    start)
      [[ -n "$CODE" ]] || { echo "Missing activation code. Use --code or EXPRESSVPN_CODE."; exit 1; }
      start_all
      ;;
    stop)
      stop_all
      ;;
    status)
      status_all
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
