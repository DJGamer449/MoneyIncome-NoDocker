#!/usr/bin/env bash
set -euo pipefail

ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true

# ==========================================
# DIRECT WIPTER MULTI-INSTANCE LAUNCHER
# Per-proxy netns + tun2socks routing + isolated Wipter seed/profile
# ==========================================

PROXY_FILE="${1:-proxies.txt}"

# Proxy checks
CHECK_WORKING="${CHECK_WORKING:-1}"
CHECK_SPEED="${CHECK_SPEED:-0}"
MAX_LAT_MS="${MAX_LAT_MS:-1500}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"

# DNS & routing
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_multi}"
mkdir -p "$WORKDIR"

FWMARK="${FWMARK:-0x22b}"
TUN_TABLE="${TUN_TABLE:-100}"
BYPASS_UDP53="${BYPASS_UDP53:-1}"
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-0}"

# Wipter runtime behavior
HEADLESS="${HEADLESS:-1}"
RUN_AFTER_SEED="${RUN_AFTER_SEED:-1}"
SKIP_KEYTAR="${SKIP_KEYTAR:-0}"
KEYRING_PASSWORD="${KEYRING_PASSWORD:-}"
TAIL_LOGS="${TAIL_LOGS:-1}"
GLOBAL_WIPTER_LOG="${GLOBAL_WIPTER_LOG:-/tmp/wipter-run.log}"

# Wipter needs localStorage in addition to the OS keychain token. Keep the
# localStorage seed enabled by default. DevTools is safe on fixed 9222 because
# every instance has its own network namespace and loopback.
WIPTER_LOCALSTORAGE_SEED="${WIPTER_LOCALSTORAGE_SEED:-1}"
WIPTER_DEVTOOLS_PORT="${WIPTER_DEVTOOLS_PORT:-9222}"
WIPTER_CLEAR_AUTH_STORAGE="${WIPTER_CLEAR_AUTH_STORAGE:-1}"
WIPTER_VERIFY_LOCALSTORAGE="${WIPTER_VERIFY_LOCALSTORAGE:-1}"
WIPTER_SEED_SETTLE_SECONDS="${WIPTER_SEED_SETTLE_SECONDS:-3}"
WIPTER_LAST_AUTH_USER="${WIPTER_LAST_AUTH_USER:-}"

# Default for tun2socks branch: defer tun2socks until after DevTools/localStorage
# seed, so localhost 127.0.0.1:9222 stays normal during the seed phase. The
# after-seed hook then starts tun2socks before final Wipter launch.
DEFER_TUNNEL_UNTIL_AFTER_SEED="${DEFER_TUNNEL_UNTIL_AFTER_SEED:-$WIPTER_LOCALSTORAGE_SEED}"

# main.sh passes WIPTER_EMAIL/WIPTER_PASSWORD. The seed script also supports
# EMAIL/PASSWORD, so normalize once here and pass both names to each instance.
WIPTER_EMAIL="${WIPTER_EMAIL:-${EMAIL:-}}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-${PASSWORD:-}}"

APP_PIDS=()
TUNNEL_PIDS=()
TAIL_PIDS=()

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 $PROXY_FILE"
    exit 1
  fi
  command -v ip >/dev/null 2>&1 || { echo "iproute2 is required"; exit 1; }
  command -v iptables >/dev/null 2>&1 || { echo "iptables is required"; exit 1; }
  command -v curl >/dev/null 2>&1 || { echo "curl is required"; exit 1; }
  command -v uuidgen >/dev/null 2>&1 || { echo "uuid-runtime is required"; exit 1; }
  command -v tun2socks >/dev/null 2>&1 || { echo "tun2socks not found in PATH. Run option 6 in main.sh first."; exit 1; }
  command -v wipter-app >/dev/null 2>&1 || { echo "wipter-app not found in PATH. Install Wipter first from main.sh."; exit 1; }
  [[ -x /opt/Wipter/wipter-app.bin ]] || { echo "/opt/Wipter/wipter-app.bin not found/executable. Install Wipter first from main.sh."; exit 1; }
}

ask_credentials_if_needed() {
  if [[ -z "${WIPTER_EMAIL:-}" ]]; then
    read -rp "Wipter email: " WIPTER_EMAIL
  fi
  if [[ -z "${WIPTER_PASSWORD:-}" ]]; then
    read -rsp "Wipter password: " WIPTER_PASSWORD
    echo
  fi
  export WIPTER_EMAIL WIPTER_PASSWORD EMAIL="$WIPTER_EMAIL" PASSWORD="$WIPTER_PASSWORD"
}

write_wipter_runner() {
  local runner="${WIPTER_RUNNER_SCRIPT:-}"
  if [[ -n "$runner" && -x "$runner" ]]; then
    echo "$runner"
    return 0
  fi

  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  runner="$script_dir/wipter.sh"
  if [[ -x "$runner" ]]; then
    echo "$runner"
    return 0
  fi

  echo "wipter.sh runner was not found or not executable next to direct_wipter.sh" >&2
  echo "Place wipter.sh in $script_dir and run: chmod +x wipter.sh" >&2
  exit 1
}

calc_octets() {
  local idx="$1"
  local B=$(( (idx-1) / 254 + 1 ))
  local C=$(( (idx-1) % 254 + 1 ))
  echo "$B" "$C"
}

parse_proxy() {
  local line="$1"
  local proto rest user pass hostport host port creds

  if [[ "$line" != *://* ]]; then
    echo "UNSUPPORTED_PROTO"
    return 1
  fi

  proto="${line%%://*}"
  rest="${line#*://}"
  case "$proto" in
    socks5|socks5h|http|https) ;;
    *) echo "UNSUPPORTED_PROTO"; return 1 ;;
  esac

  if [[ "$rest" == *@* ]]; then
    creds="${rest%%@*}"
    hostport="${rest#*@}"
    user="${creds%%:*}"
    if [[ "$creds" == *:* ]]; then
      pass="${creds#*:}"
    else
      pass=""
    fi
  else
    user=""
    pass=""
    hostport="$rest"
  fi

  host="${hostport%:*}"
  port="${hostport##*:}"
  [[ -n "$host" && -n "$port" && "$port" =~ ^[0-9]+$ ]] || return 1
  echo "$proto" "$user" "$pass" "$host" "$port"
}

normalize_proxy_for_tun2socks() {
  local proxy="$1"
  if [[ "$proxy" == socks5h://* ]]; then
    echo "socks5://${proxy#socks5h://}"
  else
    echo "$proxy"
  fi
}

check_proxy() {
  local proxy="$1"
  local start end ms p
  p="$proxy"
  if [[ "$p" == socks5://* ]]; then
    p="socks5h://${p#socks5://}"
  fi
  start="$(date +%s%3N)"
  if ! curl -fsS --proxy "$p" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" "http://1.1.1.1" >/dev/null; then
    echo "FAIL"
    return 1
  fi
  end="$(date +%s%3N)"
  ms=$(( end - start ))
  if [[ "$CHECK_SPEED" == "1" ]] && (( ms > MAX_LAT_MS )); then
    echo "SLOW ${ms}ms"
    return 2
  fi
  echo "OK ${ms}ms"
}

setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w fs.inotify.max_user_instances=1048576 >/dev/null 2>&1 || true
  sysctl -w fs.inotify.max_user_watches=1048576 >/dev/null 2>&1 || true
  sysctl -w fs.inotify.max_queued_events=1048576 >/dev/null 2>&1 || true
  if ! iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
  fi
  if ! iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
  fi
  if ! iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  fi
}

create_ns_with_veth() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"
  local veth_host="${VETH_PREFIX}${idx}h"
  local veth_ns="${VETH_PREFIX}${idx}n"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  ip netns add "$ns" 2>/dev/null || true
  if ! ip link show "$veth_host" >/dev/null 2>&1; then
    ip link add "$veth_host" type veth peer name "$veth_ns"
  fi
  ip link set "$veth_ns" netns "$ns" 2>/dev/null || true
  ip addr add "10.${B}.${C}.1/24" dev "$veth_host" 2>/dev/null || true
  ip link set "$veth_host" up
  ip netns exec "$ns" ip addr add "10.${B}.${C}.2/24" dev "$veth_ns" 2>/dev/null || true
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$veth_ns" up
  ip netns exec "$ns" ip route replace default via "10.${B}.${C}.1" dev "$veth_ns"

  if [[ "$FORCE_NS_DNS" == "1" ]]; then
    mkdir -p "/etc/netns/$ns"
    : > "/etc/netns/$ns/resolv.conf"
    for d in $NS_DNS_LIST; do
      echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"
    done
  fi
  echo "$ns"
}

pin_proxy_route_in_ns() {
  local ns="$1" idx="$2" proxy_host="$3"
  local B C gw dev
  read -r B C <<<"$(calc_octets "$idx")"
  gw="10.${B}.${C}.1"
  dev="${VETH_PREFIX}${idx}n"

  if [[ "$proxy_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip netns exec "$ns" ip route replace "$proxy_host/32" via "$gw" dev "$dev" || true
  else
    mapfile -t ips < <(getent ahostsv4 "$proxy_host" | awk '{print $1}' | sort -u)
    for ip in "${ips[@]}"; do
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done
  fi
}

bypass_dns_via_veth() {
  local ns="$1" idx="$2"
  local B C gw dev resolv
  read -r B C <<<"$(calc_octets "$idx")"
  gw="10.${B}.${C}.1"
  dev="${VETH_PREFIX}${idx}n"
  resolv="/etc/netns/$ns/resolv.conf"

  if [[ -f "$resolv" ]]; then
    while read -r _ ip; do
      [[ "${_:-}" == "nameserver" ]] || continue
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done < <(grep -E '^\s*nameserver\s+' "$resolv")
  else
    for ip in 1.1.1.1 8.8.8.8; do
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" || true
    done
  fi
}

reset_ns_firewall_allow_all() {
  local ns="$1"
  ip netns exec "$ns" sh -c '
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -t raw -F 2>/dev/null || true
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
  '
}

configure_policy_routing() {
  local ns="$1" idx="$2"
  local B C gw dev
  read -r B C <<<"$(calc_octets "$idx")"
  gw="10.${B}.${C}.1"
  dev="${VETH_PREFIX}${idx}n"

  ip netns exec "$ns" ip route replace default via "$gw" dev "$dev" 2>/dev/null || true
  ip netns exec "$ns" ip route flush table "$TUN_TABLE" 2>/dev/null || true

  # Keep localhost/devtools traffic on loopback even after the catch-all tunnel rule.
  ip netns exec "$ns" ip route add local 127.0.0.0/8 dev lo table "$TUN_TABLE" 2>/dev/null || \
    ip netns exec "$ns" ip route replace 127.0.0.0/8 dev lo table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip route add default dev tun0 table "$TUN_TABLE" 2>/dev/null || true

  ip netns exec "$ns" ip rule add to 127.0.0.0/8 lookup main priority 10 2>/dev/null || true
  ip netns exec "$ns" ip rule add from 127.0.0.0/8 lookup main priority 11 2>/dev/null || true
  ip netns exec "$ns" ip rule add fwmark "$FWMARK" lookup main priority 100 2>/dev/null || true
  if [[ "$BYPASS_ALL_UDP" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp lookup main priority 101 2>/dev/null || true
  elif [[ "$BYPASS_UDP53" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp dport 53 lookup main priority 101 2>/dev/null || true
    ip netns exec "$ns" ip rule add iif lo ipproto udp dport 53 lookup main priority 102 2>/dev/null || true
  fi
  ip netns exec "$ns" ip rule add lookup "$TUN_TABLE" priority 200 2>/dev/null || true
}

create_tun0_in_ns() {
  local ns="$1" idx="$2"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"
  ip netns exec "$ns" ip link del tun0 2>/dev/null || true
  ip netns exec "$ns" ip tuntap add dev tun0 mode tun
  ip netns exec "$ns" ip addr add "198.18.${B}.${C}/30" dev tun0
  ip netns exec "$ns" ip link set tun0 up
}

write_after_seed_hook() {
  local idx="$1" ns="$2" tun_proxy="$3" t_logfile="$4" t_pidfile="$5"
  local B C gw dev hook_file q_proxy q_log q_pid q_tun_table q_fwmark
  read -r B C <<<"$(calc_octets "$idx")"
  gw="10.${B}.${C}.1"
  dev="${VETH_PREFIX}${idx}n"
  hook_file="$WORKDIR/after_seed_tun2socks_${idx}.sh"

  printf -v q_proxy '%q' "$tun_proxy"
  printf -v q_log '%q' "$t_logfile"
  printf -v q_pid '%q' "$t_pidfile"
  printf -v q_tun_table '%q' "$TUN_TABLE"
  printf -v q_fwmark '%q' "$FWMARK"

  cat >"$hook_file" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "[after-seed] creating tun0 and starting tun2socks after DevTools/localStorage seed"
echo "[after-seed] tunnel log: $t_logfile"

ip link del tun0 2>/dev/null || true
ip tuntap add dev tun0 mode tun
ip addr add "198.18.${B}.${C}/30" dev tun0
ip link set tun0 up

tun2socks -device tun0 -proxy $q_proxy -fwmark $q_fwmark >$q_log 2>&1 &
echo \$! > $q_pid

for i in {1..80}; do
  ip link show tun0 >/dev/null 2>&1 && break
  sleep 0.1
done

if ! ip link show tun0 >/dev/null 2>&1; then
  echo "[after-seed] tun0 was not created. Check $t_logfile" >&2
  exit 1
fi

ip route replace default via '$gw' dev '$dev' 2>/dev/null || true
ip route flush table $q_tun_table 2>/dev/null || true

# Keep localhost/devtools/local IPC traffic on loopback.
ip route add local 127.0.0.0/8 dev lo table $q_tun_table 2>/dev/null || \
  ip route replace 127.0.0.0/8 dev lo table $q_tun_table 2>/dev/null || true
ip route add default dev tun0 table $q_tun_table 2>/dev/null || true

ip rule add to 127.0.0.0/8 lookup main priority 10 2>/dev/null || true
ip rule add from 127.0.0.0/8 lookup main priority 11 2>/dev/null || true
ip rule add fwmark $q_fwmark lookup main priority 100 2>/dev/null || true
EOF

  if [[ "$BYPASS_ALL_UDP" == "1" ]]; then
    cat >>"$hook_file" <<EOF
ip rule add ipproto udp lookup main priority 101 2>/dev/null || true
EOF
  elif [[ "$BYPASS_UDP53" == "1" ]]; then
    cat >>"$hook_file" <<EOF
ip rule add ipproto udp dport 53 lookup main priority 101 2>/dev/null || true
ip rule add iif lo ipproto udp dport 53 lookup main priority 102 2>/dev/null || true
EOF
  fi

  cat >>"$hook_file" <<EOF
ip rule add lookup $q_tun_table priority 200 2>/dev/null || true

if [ -f /etc/resolv.conf ]; then
  awk '/^nameserver[[:space:]]+[0-9.]+/ {print \$2}' /etc/resolv.conf | while read -r ip; do
    ip route replace "\$ip/32" via '$gw' dev '$dev' 2>/dev/null || true
  done
fi

iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t raw -F 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true

echo "[after-seed] tun2socks tunnel and policy route are active; final Wipter launch will use the proxy"
EOF
  chmod +x "$hook_file"
  echo "$hook_file"
}

start_log_aggregator() {
  local idx="$1" app_log="$2" runtime_log="$3"
  touch "$app_log" "$runtime_log" "$GLOBAL_WIPTER_LOG"
  if [[ "$TAIL_LOGS" == "1" ]]; then
    (
      tail -n +1 -F "$app_log" "$runtime_log" 2>/dev/null | sed -u "s/^/[wipter-${idx}] /"
    ) >> "$GLOBAL_WIPTER_LOG" &
    TAIL_PIDS+=("$!")
  fi
}

start_tun2socks_and_wipter() {
  local idx="$1" proxy="$2" runner="$3"
  local parsed proto user pass host port ns B C t_pidfile t_logfile tun_proxy after_seed_hook

  parsed="$(parse_proxy "$proxy")" || { echo "[$idx] Bad or unsupported proxy: $proxy"; return 1; }
  read -r proto user pass host port <<<"$parsed"
  tun_proxy="$(normalize_proxy_for_tun2socks "$proxy")"

  ns="$(create_ns_with_veth "$idx")"
  read -r B C <<<"$(calc_octets "$idx")"
  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  t_pidfile="$WORKDIR/tun2socks_${idx}.pid"
  t_logfile="$WORKDIR/tun2socks_${idx}.log"

  after_seed_hook=""
  if [[ "$DEFER_TUNNEL_UNTIL_AFTER_SEED" == "1" ]]; then
    after_seed_hook="$(write_after_seed_hook "$idx" "$ns" "$tun_proxy" "$t_logfile" "$t_pidfile")"
  else
    create_tun0_in_ns "$ns" "$idx"
    ip netns exec "$ns" bash -c "
      tun2socks -device tun0 -proxy '$tun_proxy' -fwmark '$FWMARK' >'$t_logfile' 2>&1 &
      echo \$! > '$t_pidfile'
    "
    configure_policy_routing "$ns" "$idx"
    bypass_dns_via_veth "$ns" "$idx"
    reset_ns_firewall_allow_all "$ns"
  fi

  # ==========================================
  # WIPTER FILESYSTEM / SEED ISOLATION
  # ==========================================
  local inst_dir="$WORKDIR/inst_${idx}"
  local inst_home="$inst_dir/home"
  local inst_data="$inst_dir/xdg-data"
  local inst_config="$inst_dir/xdg-config"
  local inst_cache="$inst_dir/xdg-cache"
  local inst_runtime="$inst_dir/runtime"
  local inst_logs="$inst_dir/logs"
  local inst_profile="$inst_dir/wipter-profile"
  local seed_file="$inst_dir/seed_id"
  local app_log="$WORKDIR/app_${idx}.log"
  local runtime_log="$inst_logs/wipter-run.log"
  local devtools_port="$WIPTER_DEVTOOLS_PORT"

  mkdir -p "$inst_home" "$inst_data" "$inst_config" "$inst_cache" "$inst_runtime" "$inst_logs" "$inst_profile"
  chmod 700 "$inst_runtime"
  : > "$app_log"
  : > "$runtime_log"
  : > "$inst_logs/wipter-seed-launch.log"
  : > "$inst_logs/wipter-seed-keyring.log"
  if [[ ! -f "$seed_file" ]]; then
    uuidgen > "$seed_file"
  fi

  echo "[$idx] Starting Wipter via proxy=$proxy"
  echo "[$idx] Tunnel engine=tun2socks"
  if [[ "$WIPTER_LOCALSTORAGE_SEED" == "1" ]]; then
    echo "[$idx] Seed method=keytar + DevTools localStorage injection on fixed port $devtools_port"
  else
    echo "[$idx] Seed method=keytar only (diagnostic fallback; Wipter may still redirect to sign in)"
  fi
  if [[ "$DEFER_TUNNEL_UNTIL_AFTER_SEED" == "1" ]]; then
    echo "[$idx] Tunnel method=deferred until after seed"
  else
    echo "[$idx] Tunnel method=immediate; Cognito login and final app use proxy route"
  fi
  echo "[$idx] Namespace=$ns DevTools=127.0.0.1:$devtools_port (per-netns loopback)"
  echo "[$idx] Seed/profile: $inst_dir"
  echo "[$idx] Wipter app log: $runtime_log"
  echo "[$idx] tun2socks log: $t_logfile"
  echo "[$idx] Combined Wipter logs: $GLOBAL_WIPTER_LOG (inside app log name is /tmp/wipter-run.log equivalent)"
  {
    echo "[$(date -Is)] [wipter-${idx}] starting via proxy=$proxy"
    echo "[$(date -Is)] [wipter-${idx}] namespace=$ns seed=$inst_dir app_log=$runtime_log tunnel_log=$t_logfile engine=tun2socks"
  } >> "$GLOBAL_WIPTER_LOG"

  start_log_aggregator "$idx" "$app_log" "$runtime_log"

  ip netns exec "$ns" env \
    HOME="$inst_home" \
    USER="wipter${idx}" \
    LOGNAME="wipter${idx}" \
    XDG_DATA_HOME="$inst_data" \
    XDG_CONFIG_HOME="$inst_config" \
    XDG_CACHE_HOME="$inst_cache" \
    XDG_RUNTIME_DIR="$inst_runtime" \
    EMAIL="$WIPTER_EMAIL" \
    PASSWORD="$WIPTER_PASSWORD" \
    WIPTER_EMAIL="$WIPTER_EMAIL" \
    WIPTER_PASSWORD="$WIPTER_PASSWORD" \
    HEADLESS="$HEADLESS" \
    RUN_AFTER_SEED="$RUN_AFTER_SEED" \
    SKIP_KEYTAR="$SKIP_KEYTAR" \
    KEYRING_PASSWORD="$KEYRING_PASSWORD" \
    WIPTER_DEVTOOLS_PORT="$devtools_port" \
    WIPTER_USER_DATA_DIR="$inst_profile" \
    WIPTER_AFTER_SEED_HOOK="$after_seed_hook" \
    WIPTER_LOCALSTORAGE_SEED="$WIPTER_LOCALSTORAGE_SEED" \
    WIPTER_CLEAR_AUTH_STORAGE="$WIPTER_CLEAR_AUTH_STORAGE" \
    WIPTER_VERIFY_LOCALSTORAGE="$WIPTER_VERIFY_LOCALSTORAGE" \
    WIPTER_SEED_SETTLE_SECONDS="$WIPTER_SEED_SETTLE_SECONDS" \
    WIPTER_LAST_AUTH_USER="$WIPTER_LAST_AUTH_USER" \
    WIPTER_LOG="$inst_logs/wipter-seed-launch.log" \
    FINAL_WIPTER_LOG="$runtime_log" \
    KEYRING_LOG="$inst_logs/wipter-seed-keyring.log" \
    PATH="$PATH" \
    bash "$runner" --hidden >"$app_log" 2>&1 &
  APP_PIDS+=("$!")
  echo "$!" > "$WORKDIR/app_${idx}.pid"
}

cleanup() {
  echo
  echo "Cleaning up Wipter tun2socks instances..."
  for pid in "${TAIL_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for f in "$WORKDIR"/tun2socks_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  for ns in $(ip netns list | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" || true); do
    local idx="${ns#$BASE_NS}"
    ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
    rm -rf "/etc/netns/$ns" 2>/dev/null || true
  done
  echo "Cleanup complete. Persistent isolated Wipter seeds remain in $WORKDIR/inst_*"
}

main() {
  require_root
  ask_credentials_if_needed
  setup_nat_once
  local runner
  runner="$(write_wipter_runner)"

  [[ -f "$PROXY_FILE" ]] || { echo "Proxy file not found: $PROXY_FILE"; exit 1; }
  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  (( ${#proxies[@]} > 0 )) || { echo "No proxies in $PROXY_FILE"; exit 1; }

  : > "$GLOBAL_WIPTER_LOG"
  echo "Loaded ${#proxies[@]} proxies from $PROXY_FILE"
  echo "Combined Wipter log: $GLOBAL_WIPTER_LOG"

  local used=0 i=0 p res
  for p in "${proxies[@]}"; do
    i=$((i+1))
    if [[ "$CHECK_WORKING" == "1" ]]; then
      res="$(check_proxy "$p" || true)"
      if [[ "$res" == FAIL* ]]; then
        echo "[src#$i] dead: $p"
        continue
      fi
      echo "[src#$i] ok ($res): $p"
    fi
    used=$((used+1))
    start_tun2socks_and_wipter "$used" "$p" "$runner"
    sleep 15
  done

  if (( used > 0 )); then
    echo "------------------------------------------------"
    echo "Started $used Wipter instance(s) using tun2socks."
    echo "Combined live log: $GLOBAL_WIPTER_LOG"
    echo "Per-instance logs: $WORKDIR/inst_N/logs/wipter-run.log"
    echo "tun2socks logs: $WORKDIR/tun2socks_N.log"
    echo "Each instance has isolated HOME/XDG/keyring/profile files in $WORKDIR/inst_N"
    echo "Press Ctrl+C to stop all instances."
    echo "------------------------------------------------"
    wait
  else
    echo "No usable proxies after filtering."
    exit 1
  fi
}

trap cleanup EXIT
main "$@"
