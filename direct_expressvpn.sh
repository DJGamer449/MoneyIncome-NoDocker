#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPRESSVPNCTL="${EXPRESSVPNCTL:-$BASE_DIR/app/expressvpn/expressvpnctl}"
BATCH_SIZE="${BATCH_SIZE:-50}"
NETNS_PREFIX="${NETNS_PREFIX:-expressvpn}"
STATE_DIR="${STATE_DIR:-/tmp/expressvpn-netns}"

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

log() {
  echo "[expressvpn-netns] $*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

require_ctl() {
  if [[ ! -x "$EXPRESSVPNCTL" ]]; then
    echo "expressvpnctl not executable at: $EXPRESSVPNCTL"
    exit 1
  fi
}

host_iface() {
  ip route show default | awk '/default/ {print $5; exit}'
}

create_ns() {
  local idx="$1"
  local ns="$2"
  local host_if="xvph${idx}"
  local ns_if="xvpn${idx}"
  local subnet="10.233.${idx}.0/24"

  ip netns add "$ns"
  ip link add "$host_if" type veth peer name "$ns_if"
  ip link set "$ns_if" netns "$ns"
  ip addr add "10.233.${idx}.1/24" dev "$host_if"
  ip link set "$host_if" up

  ip netns exec "$ns" ip addr add "10.233.${idx}.2/24" dev "$ns_if"
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route add default via "10.233.${idx}.1"

  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"

  iptables -t nat -C POSTROUTING -s "$subnet" -o "$(host_iface)" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$(host_iface)" -j MASQUERADE
}

connect_ns() {
  local ns="$1"
  local alias="$2"
  local root_dir="$STATE_DIR/$ns"

  mkdir -p "$root_dir/home"
  chmod 700 "$root_dir/home"

  ip netns exec "$ns" env \
    HOME="$root_dir/home" \
    XDG_CONFIG_HOME="$root_dir/home/.config" \
    XDG_CACHE_HOME="$root_dir/home/.cache" \
    SERVER="$alias" \
    CODE="$EXPRESSVPN_CODE" \
    EXPRESSVPNCTL="$EXPRESSVPNCTL" \
    bash -lc '
      set -euo pipefail
      code_file=$(mktemp)
      printf "%s" "$CODE" > "$code_file"
      "$EXPRESSVPNCTL" --timeout 60 login "$code_file" >/dev/null 2>&1 || true
      rm -f "$code_file"
      "$EXPRESSVPNCTL" set protocol "${PROTOCOL:-lightwayudp}" >/dev/null 2>&1 || true
      "$EXPRESSVPNCTL" connect "$SERVER"
    ' >"$root_dir/connect.log" 2>&1 &
}

is_connected() {
  local ns="$1"
  ip netns exec "$ns" env HOME="$STATE_DIR/$ns/home" "$EXPRESSVPNCTL" get connectionstate 2>/dev/null | grep -q '^Connected$'
}

wait_batch_connected() {
  local -a nss=("$@")
  local timeout="${CONNECT_TIMEOUT:-300}"
  local waited=0

  while (( waited < timeout )); do
    local all_ok=1
    local ns
    for ns in "${nss[@]}"; do
      if ! is_connected "$ns"; then
        all_ok=0
        break
      fi
    done

    if (( all_ok == 1 )); then
      return 0
    fi

    sleep 2
    waited=$((waited + 2))
  done

  return 1
}

start_all() {
  if [[ -z "${EXPRESSVPN_CODE:-}" ]]; then
    read -rsp "Enter ExpressVPN activation code: " EXPRESSVPN_CODE
    echo
  fi

  local total="${#aliases[@]}"
  local start=0

  while (( start < total )); do
    local end=$((start + BATCH_SIZE))
    (( end > total )) && end=$total

    log "Launching batch $((start + 1))-$end of $total"
    local -a batch_ns=()
    local i

    for (( i=start; i<end; i++ )); do
      local idx=$((i + 1))
      local ns="${NETNS_PREFIX}-${idx}"
      local alias="${aliases[$i]}"

      ip netns list | awk '{print $1}' | grep -qx "$ns" && {
        log "Namespace $ns already exists, skipping"
        batch_ns+=("$ns")
        continue
      }

      create_ns "$idx" "$ns"
      connect_ns "$ns" "$alias"
      batch_ns+=("$ns")
      log "Started $ns -> $alias"
      sleep 0.3
    done

    if wait_batch_connected "${batch_ns[@]}"; then
      log "Batch $((start / BATCH_SIZE + 1)) connected."
    else
      log "Batch $((start / BATCH_SIZE + 1)) timeout waiting for connected state."
      exit 1
    fi

    start="$end"
  done

  log "All namespaces launched and connected."
}

stop_all() {
  local total="${#aliases[@]}"
  local host_if
  host_if="$(host_iface)"

  for (( i=1; i<=total; i++ )); do
    local ns="${NETNS_PREFIX}-${i}"
    local subnet="10.233.${i}.0/24"

    if ip netns list | awk '{print $1}' | grep -qx "$ns"; then
      ip netns exec "$ns" env HOME="$STATE_DIR/$ns/home" "$EXPRESSVPNCTL" disconnect >/dev/null 2>&1 || true
      ip netns delete "$ns" || true
      rm -rf "/etc/netns/$ns" "$STATE_DIR/$ns"
    fi

    iptables -t nat -D POSTROUTING -s "$subnet" -o "$host_if" -j MASQUERADE 2>/dev/null || true
  done

  log "Stopped and removed all ExpressVPN namespaces."
}

status_all() {
  local total="${#aliases[@]}"
  for (( i=1; i<=total; i++ )); do
    local ns="${NETNS_PREFIX}-${i}"
    if ip netns list | awk '{print $1}' | grep -qx "$ns"; then
      if is_connected "$ns"; then
        echo "$ns connected"
      else
        echo "$ns not-connected"
      fi
    fi
  done
}

main() {
  require_root
  require_ctl

  local action="${1:-start}"
  case "$action" in
    start) start_all ;;
    stop) stop_all ;;
    status) status_all ;;
    *)
      echo "Usage: $0 [start|stop|status]"
      exit 1
      ;;
  esac
}

main "$@"
