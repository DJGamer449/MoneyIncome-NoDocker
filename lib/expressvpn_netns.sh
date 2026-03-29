#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/instance_regions.sh"
source "$BASE_DIR/lib/public_ip_check.sh"

EXPRESSVPN_CTL="/opt/expressvpn/bin/expressvpnctl"
EXPRESSVPN_DAEMON="/opt/expressvpn/bin/expressvpn-daemon"
EXPRESSVPN_HELPER_DIR="/opt/expressvpn"

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "[ERROR] Must run as root." >&2
    exit 1
  fi
}

require_expressvpn_bins() {
  [[ -x "$EXPRESSVPN_CTL" ]] || { echo "Missing $EXPRESSVPN_CTL" >&2; exit 1; }
  [[ -x "$EXPRESSVPN_DAEMON" ]] || { echo "Missing $EXPRESSVPN_DAEMON" >&2; exit 1; }
  [[ -d "$EXPRESSVPN_HELPER_DIR" ]] || { echo "Missing $EXPRESSVPN_HELPER_DIR" >&2; exit 1; }
}

create_netns_instance() {
  local ns="$1" idx="$2" veth_prefix="$3"
  local host_if="${veth_prefix}h${idx}" ns_if="${veth_prefix}n${idx}"
  local host_ip="10.210.${idx}.1/24" ns_ip="10.210.${idx}.2/24" subnet="10.210.${idx}.0/24"

  ip netns del "$ns" 2>/dev/null || true
  rm -rf "/etc/netns/$ns"

  ip netns add "$ns"
  ip link add "$host_if" type veth peer name "$ns_if"
  ip link set "$ns_if" netns "$ns"
  ip addr add "$host_ip" dev "$host_if"
  ip link set "$host_if" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip addr add "$ns_ip" dev "$ns_if"
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip route replace default via "10.210.${idx}.1"
  mkdir -p "/etc/netns/$ns"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"

  iptables -t nat -C POSTROUTING -s "$subnet" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$subnet" -j MASQUERADE
}

instance_paths() {
  local app="$1" idx="$2"
  local root="/tmp/${app}_multi/inst_${idx}"
  echo "$root"
}

cleanup_instance() {
  local app="$1" idx="$2" ns="$3"
  local root
  root="$(instance_paths "$app" "$idx")"

  if [[ -f "$root/app.pid" ]]; then kill -TERM "$(cat "$root/app.pid")" 2>/dev/null || true; fi
  if [[ -f "$root/vpn-supervisor.pid" ]]; then kill -TERM "$(cat "$root/vpn-supervisor.pid")" 2>/dev/null || true; fi
  if [[ -f "$root/daemon.pid" ]]; then kill -TERM "$(cat "$root/daemon.pid")" 2>/dev/null || true; fi

  ip netns pids "$ns" 2>/dev/null | xargs -r kill -TERM 2>/dev/null || true
  sleep 1
  ip netns pids "$ns" 2>/dev/null | xargs -r kill -KILL 2>/dev/null || true

  ip netns del "$ns" 2>/dev/null || true
  rm -rf "/etc/netns/$ns" "$root"
}

start_expressvpn_and_app_in_instance() {
  local app="$1" idx="$2" ns="$3" region="$4" key="$5" app_cmd="$6"
  local root vpn_dir home_dir xdg_dir log_file
  root="$(instance_paths "$app" "$idx")"
  vpn_dir="$root/expressvpn"
  home_dir="$root/home"
  xdg_dir="$root/xdg"
  log_file="$root/instance.log"

  mkdir -p "$vpn_dir"/{run,lib,etc,log} "$home_dir" "$xdg_dir" "$root"

  cat > "$root/run_instance.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

APP="$1"; IDX="$2"; REGION="$3"; KEY="$4"; ROOT="$5"; VPN_DIR="$6"; HOME_DIR="$7"; XDG_DIR="$8"; LOG_FILE="$9"; APP_CMD="${10}"
EXPRESSVPN_CTL="/opt/expressvpn/bin/expressvpnctl"
EXPRESSVPN_DAEMON="/opt/expressvpn/bin/expressvpn-daemon"

mkdir -p "$VPN_DIR"/{run,lib,etc,log} "$HOME_DIR" "$XDG_DIR"

export HOME="$HOME_DIR"
export XDG_CONFIG_HOME="$XDG_DIR/config"
export XDG_CACHE_HOME="$XDG_DIR/cache"
export XDG_STATE_HOME="$XDG_DIR/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

mount --make-rprivate /
mount --bind "$VPN_DIR/lib" /var/lib/expressvpn
mount --bind "$VPN_DIR/run" /var/run
mount --bind "$VPN_DIR/etc" /etc/expressvpn
mount --bind "$VPN_DIR/log" /var/log

"$EXPRESSVPN_DAEMON" >"$VPN_DIR/log/daemon.log" 2>&1 &
echo $! > "$ROOT/daemon.pid"

for _ in {1..30}; do
  "$EXPRESSVPN_CTL" --help >/dev/null 2>&1 && break
  sleep 1
done

if ! "$EXPRESSVPN_CTL" preferences set network_lock on >>"$LOG_FILE" 2>&1; then
  echo "[inst-${IDX}] unable to enable network lock" >>"$LOG_FILE"
fi
"$EXPRESSVPN_CTL" activate "$KEY" >>"$LOG_FILE" 2>&1 || true
"$EXPRESSVPN_CTL" connect "$REGION" >>"$LOG_FILE" 2>&1
"$EXPRESSVPN_CTL" status >>"$LOG_FILE" 2>&1

if ! "$EXPRESSVPN_CTL" status | grep -qi 'Connected'; then
  echo "[inst-${IDX}] VPN failed to connect" >>"$LOG_FILE"
  exit 21
fi

bash -lc "$APP_CMD" >>"$LOG_FILE" 2>&1 &
echo $! > "$ROOT/app.pid"
wait $(cat "$ROOT/app.pid")
SCRIPT

  chmod +x "$root/run_instance.sh"

  ip netns exec "$ns" unshare --mount --pid --fork --mount-proc \
    "$root/run_instance.sh" "$app" "$idx" "$region" "$key" "$root" "$vpn_dir" "$home_dir" "$xdg_dir" "$log_file" "$app_cmd" &
  echo $! > "$root/vpn-supervisor.pid"
}

run_isolated_expressvpn_app() {
  local app="$1" instances="$2" activation_key="$3" app_cmd_template="$4"
  local idx ns region ip retry max_retries=4
  local -a observed_ips=()

  require_root
  require_expressvpn_bins

  trap 'for i in $(seq 1 "$instances"); do cleanup_instance "$app" "$i" "${app}ns${i}"; done' INT TERM EXIT

  for idx in $(seq 1 "$instances"); do
    ns="${app}ns${idx}"
    create_netns_instance "$ns" "$idx" "$app"

    retry=0
    while (( retry < max_retries )); do
      region="$(region_for_index $((idx + retry)))"
      start_expressvpn_and_app_in_instance "$app" "$idx" "$ns" "$region" "$activation_key" "${app_cmd_template//\{IDX\}/$idx}"
      sleep 10
      ip="$(public_ip_from_ns "$ns" 2>/dev/null || true)"
      if [[ -z "$ip" ]]; then
        cleanup_instance "$app" "$idx" "$ns"
        create_netns_instance "$ns" "$idx" "$app"
        retry=$((retry + 1))
        continue
      fi
      if ! is_unique_public_ip "$ip" "${observed_ips[@]:-}"; then
        echo "[$app:$idx] duplicate public IP $ip on $region, retrying next region"
        cleanup_instance "$app" "$idx" "$ns"
        create_netns_instance "$ns" "$idx" "$app"
        retry=$((retry + 1))
        continue
      fi

      observed_ips+=("$ip")
      echo "[$app:$idx] ns=$ns region=$region vpn=connected public_ip=$ip app_pid=$(cat "$(instance_paths "$app" "$idx")/app.pid" 2>/dev/null || echo n/a)"
      break
    done

    if (( retry == max_retries )); then
      echo "[$app:$idx] failed to establish unique public IP after $max_retries attempts" >&2
      return 1
    fi
  done

  wait
}
