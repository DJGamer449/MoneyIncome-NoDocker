#!/usr/bin/env bash
set -euo pipefail

BATCH_SIZE="${BATCH_SIZE:-50}"
BASE_NS="${BASE_NS:-expressvpnns}"
VETH_PREFIX="${VETH_PREFIX:-xvpnveth}"
STATE_DIR="${STATE_DIR:-/tmp/expressvpn-netns}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-300}"
PROVIDER="expressvpn"

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

log() {
  echo "[expressvpn-netns] $*"
}

usage() {
  cat <<USAGE
Usage: sudo ./direct_expressvpn_netns.sh [options]

Options:
  --code <key>                ExpressVPN activation key (required)
  --provider expressvpn       VPN provider selector (only expressvpn is supported)
  --aliases a,b,c             Comma-separated subset of aliases
  --batch-size <n>            Number of namespaces per batch (default: 50)
  --app-cmd '<command>'       Command to run inside each namespace after VPN connects
  --cleanup                   Remove namespaces created with BASE_NS prefix and exit
  -h, --help                  Show this help
USAGE
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)."
    exit 1
  fi
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  if ! iptables -t nat -C POSTROUTING -s 10.200.0.0/16 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.200.0.0/16 -j MASQUERADE
  fi
  if ! iptables -C FORWARD -s 10.200.0.0/16 -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -s 10.200.0.0/16 -j ACCEPT
  fi
  if ! iptables -C FORWARD -d 10.200.0.0/16 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -d 10.200.0.0/16 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  fi
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx - 1) / 254 + 1 ))
  local c=$(( (idx - 1) % 254 + 1 ))
  echo "$b" "$c"
}

create_ns_with_veth() {
  local idx="$1"
  local ns="$2"
  local veth_host="${VETH_PREFIX}${idx}h"
  local veth_ns="${VETH_PREFIX}${idx}n"
  local b c

  read -r b c <<<"$(calc_octets "$idx")"

  ip netns add "$ns"
  ip link add "$veth_host" type veth peer name "$veth_ns"
  ip link set "$veth_ns" netns "$ns"

  ip addr add "10.200.${b}.${c}/24" dev "$veth_host"
  ip link set "$veth_host" up

  ip netns exec "$ns" ip addr add "10.200.${b}.$((c + 1))/24" dev "$veth_ns"
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip route add default via "10.200.${b}.${c}" dev "$veth_ns"

  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"/etc/netns/$ns/resolv.conf"
}

cleanup_namespace() {
  local ns="$1"
  local idx="$2"
  ip netns del "$ns" 2>/dev/null || true
  ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
  rm -rf "/etc/netns/$ns" 2>/dev/null || true
}

cleanup_all() {
  log "Cleaning up namespaces with prefix ${BASE_NS}"
  mapfile -t existing_ns < <(ip netns list | awk '{print $1}' | rg "^${BASE_NS}[0-9]+$") || true
  for ns in "${existing_ns[@]:-}"; do
    local idx
    idx="${ns#${BASE_NS}}"
    cleanup_namespace "$ns" "$idx"
  done
  log "Cleanup completed"
}

wait_for_batch_connected() {
  local -n ns_ref=$1
  local timeout="${CONNECT_TIMEOUT}"
  local elapsed=0

  while (( elapsed < timeout )); do
    local ready=0
    for ns in "${ns_ref[@]}"; do
      if ip netns exec "$ns" bash -lc '[[ "$(expressvpnctl get connectionstate 2>/dev/null || true)" == "Connected" ]]'; then
        ready=$((ready + 1))
      fi
    done

    if (( ready == ${#ns_ref[@]} )); then
      log "Batch connected (${ready}/${#ns_ref[@]})"
      return 0
    fi

    sleep 3
    elapsed=$((elapsed + 3))
  done

  log "Batch timeout: some namespaces failed to connect within ${timeout}s"
  return 1
}

parse_args() {
  cleanup_requested=0
  selected_alias_csv=""
  APP_CMD="${APP_CMD:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code)
        CODE="$2"
        shift 2
        ;;
      --provider)
        PROVIDER="$2"
        shift 2
        ;;
      --aliases)
        selected_alias_csv="$2"
        shift 2
        ;;
      --batch-size)
        BATCH_SIZE="$2"
        shift 2
        ;;
      --app-cmd)
        APP_CMD="$2"
        shift 2
        ;;
      --cleanup)
        cleanup_requested=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$PROVIDER" != "expressvpn" ]]; then
    echo "Only --provider expressvpn is supported"
    exit 1
  fi

  if [[ "$cleanup_requested" -eq 1 ]]; then
    cleanup_all
    exit 0
  fi

  if [[ -z "${CODE:-}" ]]; then
    echo "--code is required"
    exit 1
  fi

  if ! [[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    echo "--batch-size must be a positive integer"
    exit 1
  fi

  if [[ -n "$selected_alias_csv" ]]; then
    IFS=',' read -r -a selected_aliases <<<"$selected_alias_csv"
  else
    selected_aliases=("${aliases[@]}")
  fi
}

main() {
  require_root
  parse_args "$@"

  command -v expressvpnctl >/dev/null 2>&1 || {
    echo "expressvpnctl is required"
    exit 1
  }

  mkdir -p "$STATE_DIR"
  setup_nat_once

  local total="${#selected_aliases[@]}"
  local i=0

  while (( i < total )); do
    local batch_ns=()
    local batch_end=$(( i + BATCH_SIZE ))
    if (( batch_end > total )); then
      batch_end=$total
    fi

    log "Launching batch $(( i + 1 ))-$batch_end of $total"

    for ((j=i; j<batch_end; j++)); do
      local idx=$((j + 1))
      local alias="${selected_aliases[$j]}"
      local ns="${BASE_NS}${idx}"
      local log_file="${STATE_DIR}/${ns}.log"

      cleanup_namespace "$ns" "$idx"
      create_ns_with_veth "$idx" "$ns"

      ip netns exec "$ns" env \
        CODE="$CODE" \
        SERVER="$alias" \
        APP_CMD="$APP_CMD" \
        CONNECT_TIMEOUT="$CONNECT_TIMEOUT" \
        bash "$(pwd)/expressvpn_instance.sh" >"$log_file" 2>&1 &

      batch_ns+=("$ns")
      sleep 1
    done

    wait_for_batch_connected batch_ns
    i=$batch_end
  done

  log "All namespaces launched. Logs in $STATE_DIR"
}

main "$@"
