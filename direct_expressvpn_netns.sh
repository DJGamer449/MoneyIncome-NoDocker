#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPRESSVPN_BIN_DIR="${BASE_DIR}/app/expressvpn/bin"
EXPRESSVPNCTL="${EXPRESSVPN_BIN_DIR}/expressvpnctl"
BATCH_SIZE="${BATCH_SIZE:-50}"
PROTOCOL="${PROTOCOL:-lightwayudp}"
ALLOW_LAN="${ALLOW_LAN:-true}"
BASE_NS="${BASE_NS:-xvpnns}"
BASE_WORKDIR="${BASE_WORKDIR:-/tmp/expressvpn-netns}"
APP_CMD="${APP_CMD:-}"

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
  if [[ ${EUID} -ne 0 ]]; then
    echo "Please run as root: sudo $0"
    exit 1
  fi
}

require_binaries() {
  command -v ip >/dev/null 2>&1 || { echo "iproute2 is required"; exit 1; }
  command -v iptables >/dev/null 2>&1 || { echo "iptables is required"; exit 1; }
  [[ -x "${EXPRESSVPNCTL}" ]] || {
    echo "expressvpnctl not found at ${EXPRESSVPNCTL}"
    exit 1
  }
}

read_activation_code() {
  if [[ -n "${CODE:-}" ]]; then
    return
  fi

  read -rsp "Enter ExpressVPN activation code: " CODE
  echo
  if [[ -z "${CODE}" ]]; then
    echo "Activation code cannot be empty"
    exit 1
  fi
}

read_app_command() {
  if [[ -n "${APP_CMD}" ]]; then
    return
  fi

  if [[ $# -gt 0 ]]; then
    APP_CMD="$*"
    return
  fi

  read -rp "Enter app command to run inside each connected namespace (leave blank to only prepare network): " APP_CMD
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! iptables -t nat -C POSTROUTING -s 10.240.0.0/12 -j MASQUERADE >/dev/null 2>&1; then
    iptables -t nat -A POSTROUTING -s 10.240.0.0/12 -j MASQUERADE
  fi
}

create_namespace() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local veth_h="xv${idx}h"
  local veth_n="xv${idx}n"
  local oct2=$(( (idx - 1) / 200 ))
  local oct3=$(( (idx - 1) % 200 + 1 ))
  local host_ip="10.$((240 + oct2)).${oct3}.1/24"
  local ns_ip="10.$((240 + oct2)).${oct3}.2/24"
  local gw="10.$((240 + oct2)).${oct3}.1"

  mkdir -p "${BASE_WORKDIR}/${ns}" "${BASE_WORKDIR}/${ns}/home" "${BASE_WORKDIR}/${ns}/logs"

  ip netns add "${ns}" 2>/dev/null || true
  ip link del "${veth_h}" 2>/dev/null || true
  ip link add "${veth_h}" type veth peer name "${veth_n}"
  ip link set "${veth_n}" netns "${ns}"

  ip addr add "${host_ip}" dev "${veth_h}" 2>/dev/null || true
  ip link set "${veth_h}" up

  ip netns exec "${ns}" ip link set lo up
  ip netns exec "${ns}" ip addr add "${ns_ip}" dev "${veth_n}" 2>/dev/null || true
  ip netns exec "${ns}" ip link set "${veth_n}" up
  ip netns exec "${ns}" ip route replace default via "${gw}" dev "${veth_n}"

  mkdir -p "/etc/netns/${ns}"
  cat > "/etc/netns/${ns}/resolv.conf" <<DNS
nameserver 1.1.1.1
nameserver 8.8.8.8
DNS
}

connect_one_namespace() {
  local idx="$1"
  local alias="$2"
  local ns="${BASE_NS}${idx}"
  local ns_home="${BASE_WORKDIR}/${ns}/home"
  local ns_log="${BASE_WORKDIR}/${ns}/logs/connect.log"

  ip netns exec "${ns}" env \
    HOME="${ns_home}" \
    XDG_CONFIG_HOME="${ns_home}/.config" \
    XDG_CACHE_HOME="${ns_home}/.cache" \
    XDG_DATA_HOME="${ns_home}/.local/share" \
    PATH="${EXPRESSVPN_BIN_DIR}:${PATH}" \
    CODE="${CODE}" \
    SERVER="${alias}" \
    PROTOCOL="${PROTOCOL}" \
    ALLOW_LAN="${ALLOW_LAN}" \
    bash -lc '
      set -euo pipefail
      ctl="${PATH%%:*}/expressvpnctl"

      code_file=$(mktemp)
      printf "%s" "$CODE" >"$code_file"

      "$ctl" --timeout 60 login "$code_file" >/dev/null 2>&1 || true
      rm -f "$code_file"

      "$ctl" background enable >/dev/null 2>&1 || true
      "$ctl" set protocol "$PROTOCOL" >/dev/null 2>&1 || true
      "$ctl" set allowlan "$ALLOW_LAN" >/dev/null 2>&1 || true
      "$ctl" disconnect >/dev/null 2>&1 || true
      "$ctl" connect "$SERVER" >/dev/null

      for _ in $(seq 1 20); do
        state=$("$ctl" get connectionstate 2>/dev/null || true)
        if [[ "$state" == "Connected" ]]; then
          exit 0
        fi
        sleep 2
      done

      echo "Failed to reach Connected state for $SERVER"
      exit 1
    ' >"${ns_log}" 2>&1
}

start_app_in_namespace() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local ns_home="${BASE_WORKDIR}/${ns}/home"
  local app_log="${BASE_WORKDIR}/${ns}/logs/app.log"
  local app_pid_file="${BASE_WORKDIR}/${ns}/logs/app.pid"

  [[ -n "${APP_CMD}" ]] || return 0

  ip netns exec "${ns}" env \
    HOME="${ns_home}" \
    XDG_CONFIG_HOME="${ns_home}/.config" \
    XDG_CACHE_HOME="${ns_home}/.cache" \
    XDG_DATA_HOME="${ns_home}/.local/share" \
    PATH="${EXPRESSVPN_BIN_DIR}:${PATH}" \
    bash -lc "
      nohup bash -lc $(printf '%q' "${APP_CMD}") >'${app_log}' 2>&1 &
      echo \$! > '${app_pid_file}'
    "

  log "Started app in ${ns}: ${APP_CMD}"
}

launch_batch() {
  local start_idx="$1"
  local end_idx="$2"
  local pids=()
  local idx

  for ((idx=start_idx; idx<=end_idx; idx++)); do
    local alias="${aliases[$((idx - 1))]}"
    create_namespace "${idx}"
    connect_one_namespace "${idx}" "${alias}" &
    pids+=("$!")
    log "Started namespace ${BASE_NS}${idx} -> ${alias}"
  done

  local failed=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    log "One or more namespaces in batch ${start_idx}-${end_idx} failed to connect"
    exit 1
  fi

  log "Batch ${start_idx}-${end_idx} fully connected"

  if [[ -n "${APP_CMD}" ]]; then
    for ((idx=start_idx; idx<=end_idx; idx++)); do
      start_app_in_namespace "${idx}"
    done
  fi
}

main() {
  require_root
  require_binaries
  read_activation_code
  read_app_command "$@"
  setup_nat_once

  local total="${#aliases[@]}"
  local start=1

  while [[ "$start" -le "$total" ]]; do
    local end=$((start + BATCH_SIZE - 1))
    if [[ "$end" -gt "$total" ]]; then
      end="$total"
    fi

    log "Launching batch ${start}-${end} (size $((end - start + 1)))"
    launch_batch "$start" "$end"
    start=$((end + 1))
  done

  log "All ${total} ExpressVPN namespaces connected"
  if [[ -n "${APP_CMD}" ]]; then
    log "All app processes launched inside their namespaces."
    log "Use: ip netns exec ${BASE_NS}1 bash -lc 'curl ifconfig.me' to verify per-namespace VPN exit IP."
  fi
}

main "$@"
