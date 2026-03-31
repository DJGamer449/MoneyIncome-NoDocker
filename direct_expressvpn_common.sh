#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPRESSVPN_SRC="${EXPRESSVPN_SRC:-$ROOT_DIR/app/expressvpn}"
EXPRESSVPN_SCRIPT_SRC="${EXPRESSVPN_SCRIPT_SRC:-$EXPRESSVPN_SRC/script}"
EXPRESSVPN_SERVICE_SRC="${EXPRESSVPN_SERVICE_SRC:-$EXPRESSVPN_SRC/expressvpn-service}"
REGION_FILE="${EXPRESSVPN_REGION_FILE:-$ROOT_DIR/expressvpn_region.txt}"
WORKDIR="${WORKDIR:-/tmp/expressvpn_multi}"
BASE_NS="${BASE_NS:-vpnns}"
VETH_PREFIX="${VETH_PREFIX:-vpn}"
INSTANCE_ROOT_BASE="${INSTANCE_ROOT_BASE:-/tmp/${BASE_NS}}"
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
CODE="${EXPRESSVPN_CODE:-${CODE:-}}"
APP_CMD_TEMPLATE="${APP_CMD_TEMPLATE:-}"

mkdir -p "$WORKDIR"

die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo/root."
  [[ -n "$CODE" ]] || die "Set EXPRESSVPN_CODE (activation key)."
  [[ -n "$APP_CMD_TEMPLATE" ]] || die "APP_CMD_TEMPLATE is required."
  [[ -d "$EXPRESSVPN_SRC/bin" ]] || die "Missing $EXPRESSVPN_SRC/bin"
  [[ -f "$EXPRESSVPN_SERVICE_SRC" ]] || die "Missing $EXPRESSVPN_SERVICE_SRC"
  [[ -f "$EXPRESSVPN_SCRIPT_SRC/start.sh" ]] || die "Missing $EXPRESSVPN_SCRIPT_SRC/start.sh"
}

read_regions() {
  mapfile -t REGIONS < <(tr -s '[:space:]' '\n' < "$REGION_FILE" | sed "s/^'//;s/'$//" | sed '/^$/d')
  ((${#REGIONS[@]} > 0)) || die "No regions found in $REGION_FILE"
}

region_for_index() {
  local idx="$1"
  local total="${#REGIONS[@]}"
  local pos=$(( (idx - 1) % total ))
  printf '%s' "${REGIONS[$pos]}"
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx - 1) / 254 + 1 ))
  local c=$(( (idx - 1) % 254 + 1 ))
  echo "$b" "$c"
}

create_netns() {
  local idx="$1" ns="$2"
  local b c host_if ns_if subnet
  read -r b c < <(calc_octets "$idx")
  host_if="${VETH_PREFIX}h${idx}"
  ns_if="${VETH_PREFIX}n${idx}"
  subnet="10.${b}.${c}.0/24"

  ip netns add "$ns" 2>/dev/null || true
  ip link add "$host_if" type veth peer name "$ns_if" 2>/dev/null || true
  ip link set "$ns_if" netns "$ns" 2>/dev/null || true
  ip addr replace "10.${b}.${c}.1/24" dev "$host_if"
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr replace "10.${b}.${c}.2/24" dev "$ns_if"
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$ns_if"

  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  iptables -t nat -C POSTROUTING -s "$subnet" -j MASQUERADE >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -s "$subnet" -j MASQUERADE
}

prepare_instance_files() {
  local ns="$1"
  local inst="${INSTANCE_ROOT_BASE}/${ns}"
  mkdir -p "$inst"

  if [[ ! -f "$inst/bin/expressvpnctl" || ! -f "$inst/bin/expressvpn-daemon" ]]; then
    rm -rf "$inst"
    mkdir -p "$inst"
    cp -a "$EXPRESSVPN_SRC"/* "$inst"/
  fi

  mkdir -p "$inst/etc/init.d" "$inst/bin" "$inst/tmp"
  chmod +x "$inst/bin/expressvpn-daemon" "$inst/bin/expressvpnctl" 2>/dev/null || true
  chmod +x "$inst/bin/"* 2>/dev/null || true
  cp "$EXPRESSVPN_SERVICE_SRC" "$inst/etc/init.d/expressvpn-service"
  chmod +x "$inst/etc/init.d/expressvpn-service"

  cat > "$inst/bin/service" <<'SVC'
#!/usr/bin/env bash
set -euo pipefail
svc="${1:-}"
action="${2:-}"
[[ -n "$svc" && -n "$action" ]] || exit 1
script="/etc/init.d/${svc}"
[[ -x "$script" ]] || exit 1
exec "$script" "$action"
SVC
  chmod +x "$inst/bin/service"
}

start_instance() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local region="$2"
  local app_cmd
  printf -v app_cmd "$APP_CMD_TEMPLATE" "$idx"

  create_netns "$idx" "$ns"
  prepare_instance_files "$ns"

  local inst="${INSTANCE_ROOT_BASE}/${ns}"
  local log_file="$WORKDIR/${ns}.log"
  local service_file="$inst/etc/init.d/expressvpn-service"

  ip netns exec "$ns" unshare -m bash -lc "
    set -euo pipefail
    mkdir -p /opt/expressvpn /etc/init.d /expressvpn /tmp
    mount --bind '$service_file' /etc/init.d/expressvpn-service
    mount --bind '$inst' /opt/expressvpn
    mount --bind '$EXPRESSVPN_SCRIPT_SRC' /expressvpn
    export PATH='/opt/expressvpn/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    export LD_LIBRARY_PATH=\"/opt/expressvpn/lib:\${LD_LIBRARY_PATH:-}\"
    export CODE='$CODE'
    export SERVER='$region'
    export EXPRESSVPN_TMP_ROOT='/tmp/$ns'
    export METRICS_PROMETHEUS='off'
    export CONTROL_SERVER='off'
    export SOCKS='off'
    mkdir -p \"\$EXPRESSVPN_TMP_ROOT\"
    bash /expressvpn/start.sh bash -lc $(printf '%q' "$app_cmd")
  " >"$log_file" 2>&1 &

  echo "[$idx] ns=$ns region=$region pid=$! log=$log_file"
}

main() {
  require_root
  read_regions
  local count="$INSTANCE_COUNT"
  [[ "$count" =~ ^[0-9]+$ ]] || die "INSTANCE_COUNT must be numeric"
  (( count > 0 )) || die "INSTANCE_COUNT must be > 0"

  for i in $(seq 1 "$count"); do
    start_instance "$i" "$(region_for_index "$i")"
  done

  wait
}

main "$@"
