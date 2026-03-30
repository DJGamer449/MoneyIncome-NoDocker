#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REGION_FILE="$BASE_DIR/expressvpn_region.txt"
EXPRESSVPN_BIN_SRC="$BASE_DIR/app/expressvpn/bin"
EXPRESSVPN_SCRIPT_SRC="$BASE_DIR/app/expressvpn/script"
EXPRESSVPN_SERVICE_SRC="$BASE_DIR/app/expressvpn/expressvpn-service"
WORKDIR="/tmp/expressvpn-multi"
mkdir -p "$WORKDIR"

HOST_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
HOST_IF="${HOST_IF:-eth0}"

declare -a NS_LIST=()
declare -a SUBNET_LIST=()
declare -a PID_LIST=()
declare -a REGIONS=()

require_root() {
  [[ "$EUID" -eq 0 ]] || { echo "Run as root (sudo bash main.sh)"; exit 1; }
  [[ -d "$EXPRESSVPN_BIN_SRC" ]] || { echo "Missing $EXPRESSVPN_BIN_SRC"; exit 1; }
  [[ -d "$EXPRESSVPN_SCRIPT_SRC" ]] || { echo "Missing $EXPRESSVPN_SCRIPT_SRC"; exit 1; }
  [[ -f "$EXPRESSVPN_SERVICE_SRC" ]] || { echo "Missing $EXPRESSVPN_SERVICE_SRC"; exit 1; }
  command -v ip >/dev/null 2>&1 || { echo "ip command not found"; exit 1; }
  command -v iptables >/dev/null 2>&1 || { echo "iptables command not found"; exit 1; }
  command -v unshare >/dev/null 2>&1 || { echo "unshare command not found"; exit 1; }
}

load_regions() {
  [[ -f "$REGION_FILE" ]] || { echo "Missing region file: $REGION_FILE"; exit 1; }
  mapfile -t REGIONS < <(python3 - <<'PY' "$REGION_FILE"
import shlex, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
for t in shlex.split(text):
    print(t)
PY
)
  ((${#REGIONS[@]} > 0)) || { echo "No regions found in $REGION_FILE"; exit 1; }
}

calc_octets() {
  local idx="$1"
  local b=$(( (idx - 1) / 254 + 1 ))
  local c=$(( (idx - 1) % 254 + 1 ))
  echo "$b" "$c"
}

create_ns() {
  local idx="$1"
  local ns="vpnns${idx}"
  local b c host_if ns_if subnet
  read -r b c <<<"$(calc_octets "$idx")"
  host_if="xv${idx}h"
  ns_if="xv${idx}n"
  subnet="10.${b}.${c}.0/24"

  ip netns add "$ns" 2>/dev/null || true
  ip link add "$host_if" type veth peer name "$ns_if" 2>/dev/null || true
  ip link set "$ns_if" netns "$ns"
  ip addr add "10.${b}.${c}.1/24" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$ns_if"

  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"/etc/netns/$ns/resolv.conf"

  if ! iptables -t nat -C POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
  fi

  NS_LIST+=("$ns")
  SUBNET_LIST+=("$subnet")
}

prepare_instance_files() {
  local idx="$1"
  local root="/opt/expressvpn/vpnns${idx}"
  mkdir -p "$root"/{bin,etc/init.d,var,tmp,run,www}
  cp -a "$EXPRESSVPN_BIN_SRC/." "$root/bin/"
  cp -a "$EXPRESSVPN_SERVICE_SRC" "$root/etc/init.d/expressvpn-service"
  chmod +x "$root/etc/init.d/expressvpn-service"
}

start_expressvpn_instance() {
  local idx="$1" code="$2" region="$3"
  local ns="vpnns${idx}"
  local root="/opt/expressvpn/vpnns${idx}"
  local runtime="/tmp/expressvpn_runtime_${idx}.sh"

  cat >"$runtime" <<RT
#!/usr/bin/env bash
set -euo pipefail
mount --make-rprivate /
mkdir -p /opt/expressvpn /etc/init.d /expressvpn /tmp/expressvpn
mount --bind '$root' /opt/expressvpn
mount --bind '$root/etc/init.d/expressvpn-service' /etc/init.d/expressvpn-service
mount --bind '$EXPRESSVPN_SCRIPT_SRC' /expressvpn
mount --bind '$root/tmp' /tmp/expressvpn
export PATH="/opt/expressvpn/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CODE='$code'
export SERVER='$region'
export SOCKS='off'
export CONTROL_SERVER='off'
export METRICS_PROMETHEUS='off'
chmod +x /expressvpn/*.sh 2>/dev/null || true
bash /expressvpn/start.sh >'$root/start.log' 2>&1
RT
  chmod +x "$runtime"

  ip netns exec "$ns" unshare --mount --propagation private bash "$runtime" &
  PID_LIST+=("$!")
}

run_apps_in_instance() {
  local idx="$1" ns="vpnns${idx}" base="$BASE_DIR"
  local traff_token="$2" ps_token="$3" castar_key="$4"

  ip netns exec "$ns" bash -lc "cd '$base' && nohup ./app/provider provide >/tmp/urnetwork_${idx}.log 2>&1 &" || true

  if [[ -n "$traff_token" ]]; then
    ip netns exec "$ns" bash -lc "cd '$base' && nohup ./app/cli start accept --token '$traff_token' >/tmp/traff_${idx}.log 2>&1 &" || true
  fi

  if [[ -n "$ps_token" ]]; then
    ip netns exec "$ns" bash -lc "cd '$base' && nohup env CID='$ps_token' PS_IS_DOCKER=true ./app/psclient >/tmp/ps_${idx}.log 2>&1 &" || true
  fi

  if [[ -n "$castar_key" ]]; then
    ip netns exec "$ns" bash -lc "cd '$base' && nohup ./app/CastarSDK -key='$castar_key' >/tmp/castar_${idx}.log 2>&1 &" || true
  fi

  if [[ -x "$BASE_DIR/app/honeygain_file/honeygain" && -n "${HONEYGAIN_EMAIL:-}" && -n "${HONEYGAIN_PASSWORD:-}" ]]; then
    ip netns exec "$ns" bash -lc "cd '$base' && nohup ./app/honeygain_file/honeygain -tou-accept -email '$HONEYGAIN_EMAIL' -pass '$HONEYGAIN_PASSWORD' -device 'hg-${idx}' >/tmp/honeygain_${idx}.log 2>&1 &" || true
  fi

  if [[ -x "$BASE_DIR/app/wipter/wipter.sh" && -n "${WIPTER_EMAIL:-}" && -n "${WIPTER_PASSWORD:-}" ]]; then
    ip netns exec "$ns" bash -lc "cd '$base' && nohup ./app/wipter/wipter.sh '$WIPTER_EMAIL' '$WIPTER_PASSWORD' >/tmp/wipter_${idx}.log 2>&1 &" || true
  fi
}

cleanup() {
  set +e
  for p in "${PID_LIST[@]:-}"; do kill "$p" 2>/dev/null || true; done
  for ns in "${NS_LIST[@]:-}"; do
    ip netns delete "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
  for subnet in "${SUBNET_LIST[@]:-}"; do
    iptables -t nat -D POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || true
  done
}
trap cleanup INT TERM

require_root
load_regions

read -rsp "Enter ExpressVPN activation key: " EXPRESSVPN_CODE
echo
[[ -n "$EXPRESSVPN_CODE" ]] || { echo "Activation key is required."; exit 1; }

read -rp "How many instances to run? " INSTANCE_COUNT
[[ "$INSTANCE_COUNT" =~ ^[0-9]+$ && "$INSTANCE_COUNT" -gt 0 ]] || { echo "Invalid instance count"; exit 1; }

read -rp "Traff token (optional): " TRAFF_TOKEN
read -rp "PacketStream CID token (optional): " PS_TOKEN
read -rp "Castar key (optional): " CASTAR_KEY
read -rp "Honeygain email (optional): " HONEYGAIN_EMAIL
read -rsp "Honeygain password (optional): " HONEYGAIN_PASSWORD
echo
read -rp "Wipter email (optional): " WIPTER_EMAIL
read -rsp "Wipter password (optional): " WIPTER_PASSWORD
echo

for i in $(seq 1 "$INSTANCE_COUNT"); do
  region_idx=$(( (i - 1) % ${#REGIONS[@]} ))
  region="${REGIONS[$region_idx]}"
  echo "[${i}/${INSTANCE_COUNT}] Creating vpnns${i} with region: ${region}"
  create_ns "$i"
  prepare_instance_files "$i"
  start_expressvpn_instance "$i" "$EXPRESSVPN_CODE" "$region"
  sleep 2
  run_apps_in_instance "$i" "$TRAFF_TOKEN" "$PS_TOKEN" "$CASTAR_KEY"
done

echo "All instances launched."
echo "Press Ctrl+C to stop and cleanup."
wait
