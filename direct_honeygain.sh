#!/usr/bin/env bash

set -euo pipefail

PROXY_FILE="proxies.txt"
HONEYGAIN_BIN="${HONEYGAIN_BIN:-./app/honeygain_file/honeygain}"
HONEYGAIN_ACCOUNTS_FILE="${HONEYGAIN_ACCOUNTS_FILE:-./honeygain_password.txt}"
CHECK_WORKING="${CHECK_WORKING:-1}"
CHECK_SPEED="${CHECK_SPEED:-0}"
MAX_LAT_MS="${MAX_LAT_MS:-1500}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-12}"
FORCE_NS_DNS="${FORCE_NS_DNS:-1}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
FWMARK="${FWMARK:-0x22b}"
TUN_TABLE="${TUN_TABLE:-100}"
BYPASS_UDP53="${BYPASS_UDP53:-1}"
BYPASS_ALL_UDP="${BYPASS_ALL_UDP:-0}"
DEVICES_PER_ACCOUNT=10
mkdir -p "$WORKDIR"

# Detach spawned children from the controlling terminal if possible.
# This stops honeygain/tun2socks from putting the tty into raw mode
# (which breaks Ctrl+C) and from receiving terminal-generated signals
# (which makes honeygain SIGSEGV during its cgo call on Ctrl+C).
SETSID="$(command -v setsid || true)"
SAVED_STTY=""

declare -a HONEYGAIN_ACCOUNTS=()
CLEANUP_DONE=0

# ---------------------------------------------------------------------------
# Terminal helpers
# ---------------------------------------------------------------------------
save_terminal() {
  SAVED_STTY="$(stty -g </dev/tty 2>/dev/null || true)"
}

restore_terminal() {
  if [[ -n "${SAVED_STTY:-}" ]]; then
    stty "$SAVED_STTY" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
  else
    stty sane </dev/tty 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Root / dependency checks
# ---------------------------------------------------------------------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root. Example: sudo $0 $PROXY_FILE"
    exit 1
  fi
  command -v tun2socks >/dev/null 2>&1 || { echo "tun2socks not found in PATH"; exit 1; }
  [[ -x "$HONEYGAIN_BIN" ]] || { echo "Honeygain binary not executable: $HONEYGAIN_BIN"; exit 1; }
  [[ -f "$HONEYGAIN_ACCOUNTS_FILE" ]] || { echo "Honeygain account file not found: $HONEYGAIN_ACCOUNTS_FILE"; exit 1; }
}

require_root_light() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root."
    exit 1
  fi
}

load_honeygain_accounts() {
  while IFS='|' read -r email password; do
    [[ -n "${email:-}" && -n "${password:-}" ]] || continue
    HONEYGAIN_ACCOUNTS+=("$email|$password")
  done < "$HONEYGAIN_ACCOUNTS_FILE"

  (( ${#HONEYGAIN_ACCOUNTS[@]} > 0 )) || {
    echo "No Honeygain accounts configured in $HONEYGAIN_ACCOUNTS_FILE"
    exit 1
  }
}

# ---------------------------------------------------------------------------
# Instance registry (one .meta file per running device)
# ---------------------------------------------------------------------------
write_instance_meta() {
  local idx="$1" email="$2" device_num="$3" device_name="$4" proxy="$5" ns="$6"
  cat > "$WORKDIR/inst_${idx}.meta" <<EOF
idx=$idx
email=$email
device_num=$device_num
device_name=$device_name
proxy=$proxy
ns=$ns
EOF
}

meta_get() { # file key
  sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -n1
}

instance_status() { # idx -> running|dead|stopped
  local pidf="$WORKDIR/honeygain_${1}.pid" pid
  [[ -f "$pidf" ]] || { echo "stopped"; return; }
  pid="$(cat "$pidf" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "running"
  else
    echo "dead"
  fi
}

all_indices() {
  {
    shopt -s nullglob
    local f b n
    for f in "$WORKDIR"/inst_*.meta; do meta_get "$f" idx; done
    for f in "$WORKDIR"/honeygain_*.pid "$WORKDIR"/tun2socks_*.pid; do
      b="${f##*/}"; n="${b#*_}"; n="${n%.pid}"
      [[ "$n" =~ ^[0-9]+$ ]] && echo "$n"
    done
    ip netns list 2>/dev/null | awk '{print $1}' | grep -E "^${BASE_NS}[0-9]+$" 2>/dev/null | sed "s/^${BASE_NS}//"
    shopt -u nullglob
  } 2>/dev/null | sort -un || true
}

expand_device_spec() { # "1" | "1,3,5" | "2-4" | "all"
  local spec="$1" part a b n
  if [[ "$spec" == "all" ]]; then echo "all"; return; fi
  local parts
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    part="${part// /}"
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      a="${part%-*}"; b="${part#*-}"
      for ((n=a; n<=b; n++)); do echo "$n"; done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      echo "$part"
    fi
  done
}

# ---------------------------------------------------------------------------
# Proxy handling
# ---------------------------------------------------------------------------
calc_octets() {
  local idx="$1"
  local B=$(( (idx-1) / 254 + 1 ))
  local C=$(( (idx-1) % 254 + 1 ))
  echo "$B" "$C"
}

parse_proxy() {
  local line="$1"
  local proto rest creds hostport user pass host port
  proto="${line%%://*}"
  rest="${line#*://}"
  creds="${rest%@*}"
  hostport="${rest#*@}"
  user="${creds%%:*}"
  pass="${creds#*:}"
  host="${hostport%%:*}"
  port="${hostport#*:}"

  case "$proto" in
    socks5|socks5h|http|https) ;;
    *) echo "UNSUPPORTED_PROTO"; return 1 ;;
  esac

  echo "$proto" "$user" "$pass" "$host" "$port"
}

check_proxy() {
  local proxy="$1"
  local start end ms
  local p="$proxy"
  if [[ "$p" == socks5://* ]]; then
    p="socks5h://${p#socks5://}"
  fi

  start="$(date +%s%3N)"
  if ! curl -fsS --proxy "$p" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TOTAL_TIMEOUT" "http://1.1.1.1" >/dev/null 2>&1; then
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

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
setup_nat_once() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
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
  ip link set "$veth_ns" netns "$ns"
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
  local ns="$1"
  local idx="$2"
  local proxy_host="$3"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"
  local gw="10.${B}.${C}.1"
  local dev="${VETH_PREFIX}${idx}n"

  if [[ "$proxy_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip netns exec "$ns" ip route replace "$proxy_host/32" via "$gw" dev "$dev" 2>/dev/null || true
  else
    mapfile -t ips < <(getent ahostsv4 "$proxy_host" 2>/dev/null | awk '{print $1}' | sort -u)
    for ip in "${ips[@]}"; do
      [[ -n "$ip" ]] && ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" 2>/dev/null || true
    done
  fi
}

bypass_dns_via_veth() {
  local ns="$1"
  local idx="$2"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"
  local gw="10.${B}.${C}.1"
  local dev="${VETH_PREFIX}${idx}n"
  local resolv="/etc/netns/$ns/resolv.conf"

  if [[ -f "$resolv" ]]; then
    while read -r _ ip; do
      [[ "${_:-}" == "nameserver" ]] || continue
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" 2>/dev/null || true
    done < <(grep -E '^\s*nameserver\s+' "$resolv")
  else
    for ip in 1.1.1.1 8.8.8.8; do
      ip netns exec "$ns" ip route replace "$ip/32" via "$gw" dev "$dev" 2>/dev/null || true
    done
  fi
}

reset_ns_firewall_allow_all() {
  local ns="$1"
  ip netns exec "$ns" sh -c '
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -t raw -F 2>/dev/null || true
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
  ' 2>/dev/null || true
}

configure_policy_routing() {
  local ns="$1"
  local idx="$2"
  local B C
  read -r B C <<<"$(calc_octets "$idx")"
  local gw="10.${B}.${C}.1"
  local dev="${VETH_PREFIX}${idx}n"

  ip netns exec "$ns" ip route replace default via "$gw" dev "$dev" 2>/dev/null || true
  ip netns exec "$ns" ip route flush table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip route add default dev tun0 table "$TUN_TABLE" 2>/dev/null || true
  ip netns exec "$ns" ip rule add fwmark "$FWMARK" lookup main priority 100 2>/dev/null || true
  if [[ "$BYPASS_ALL_UDP" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp lookup main priority 101 2>/dev/null || true
  elif [[ "$BYPASS_UDP53" == "1" ]]; then
    ip netns exec "$ns" ip rule add ipproto udp dport 53 lookup main priority 101 2>/dev/null || true
    ip netns exec "$ns" ip rule add iif lo ipproto udp dport 53 lookup main priority 102 2>/dev/null || true
  fi
  ip netns exec "$ns" ip rule add lookup "$TUN_TABLE" priority 200 2>/dev/null || true
}

email_mailname() {
  local email="$1"
  local localpart="${email%@*}"
  local sanitized
  sanitized="$(printf '%s' "$localpart" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')"
  printf '%s' "${sanitized:-device}"
}

# ---------------------------------------------------------------------------
# Instance start
# ---------------------------------------------------------------------------
start_tun2socks_and_honeygain() {
  local idx="$1"
  local proxy="$2"
  local email="$3"
  local password="$4"
  local device_num="$5"

  local parsed proto user pass host port
  parsed="$(parse_proxy "$proxy")" || { echo "[$idx] Bad proxy: $proxy"; return 1; }
  read -r proto user pass host port <<<"$parsed"

  local ns
  ns="$(create_ns_with_veth "$idx")"

  local B C
  read -r B C <<<"$(calc_octets "$idx")"

  ip netns exec "$ns" ip tuntap add dev tun0 mode tun 2>/dev/null || true
  ip netns exec "$ns" ip addr add "198.18.${B}.${C}/30" dev tun0 2>/dev/null || true
  ip netns exec "$ns" ip link set tun0 up 2>/dev/null || true

  pin_proxy_route_in_ns "$ns" "$idx" "$host"

  local t_pidfile="$WORKDIR/tun2socks_${idx}.pid"
  local t_logfile="$WORKDIR/tun2socks_${idx}.log"
  # setsid + </dev/null keeps this off the controlling terminal; the child
  # records its own real PID (setsid may fork, so $! is unreliable).
  $SETSID ip netns exec "$ns" bash -c "echo \$\$ > '$t_pidfile'; exec tun2socks -device tun0 -proxy '$proxy' -fwmark '$FWMARK'" </dev/null >"$t_logfile" 2>&1 &

  configure_policy_routing "$ns" "$idx"
  bypass_dns_via_veth "$ns" "$idx"
  reset_ns_firewall_allow_all "$ns"

  local inst_dir="$WORKDIR/inst_${idx}"
  local mailname
  mailname="$(email_mailname "$email")"
  local device_name="${mailname}-${device_num}"
  local app_logfile="$WORKDIR/honeygain_${idx}.log"
  mkdir -p "$inst_dir"

  echo "[$idx] Starting Honeygain for $email as device=$device_name via proxy=$proxy (netns=$ns)"
  $SETSID ip netns exec "$ns" bash -c "echo \$\$ > '$WORKDIR/honeygain_${idx}.pid'; cd '$(pwd)'; export HOME='$inst_dir'; exec '$HONEYGAIN_BIN' -tou-accept -email '$email' -pass '$password' -device '$device_name'" </dev/null >"$app_logfile" 2>&1 &

  write_instance_meta "$idx" "$email" "$device_num" "$device_name" "$proxy" "$ns"
}

# ---------------------------------------------------------------------------
# Process / instance teardown
# ---------------------------------------------------------------------------
kill_process_graceful() {
  local pidfile="$1"
  local name="$2"

  [[ -f "$pidfile" ]] || return 0

  local pid
  pid="$(cat "$pidfile" 2>/dev/null)" || return 0
  [[ -n "$pid" ]] || { rm -f "$pidfile"; return 0; }

  if kill -0 "$pid" 2>/dev/null; then
    echo "  Stopping $name (PID $pid)..."
    # Children are started with setsid, so each is its own process-group
    # leader (pgid == pid). Signal the whole group; fall back to single PID.
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

    local count=0
    while kill -0 "$pid" 2>/dev/null && (( count < 50 )); do
      sleep 0.1
      count=$((count + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
      echo "  Force killing $name (PID $pid)..."
      kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
      sleep 0.2
    fi
  fi

  rm -f "$pidfile"
}

teardown_instance() {
  local idx="$1"
  local ns="${BASE_NS}${idx}"

  kill_process_graceful "$WORKDIR/honeygain_${idx}.pid" "honeygain_${idx}"
  kill_process_graceful "$WORKDIR/tun2socks_${idx}.pid" "tun2socks_${idx}"

  ip link del "${VETH_PREFIX}${idx}h" 2>/dev/null || true
  ip netns del "$ns" 2>/dev/null || true
  rm -rf "/etc/netns/$ns" 2>/dev/null || true
  rm -f "$WORKDIR/inst_${idx}.meta" 2>/dev/null || true
}

cleanup() {
  [[ "$CLEANUP_DONE" == "1" ]] && return 0
  CLEANUP_DONE=1

  echo
  echo "Cleaning up Honeygain namespaces..."
  local idx
  for idx in $(all_indices); do
    teardown_instance "$idx"
  done
  restore_terminal
  echo "Cleanup complete."
}

# ---------------------------------------------------------------------------
# Management commands: list / stop
# ---------------------------------------------------------------------------
cmd_list() {
  shopt -s nullglob
  local metas=("$WORKDIR"/inst_*.meta)
  shopt -u nullglob
  if (( ${#metas[@]} == 0 )); then
    echo "No Honeygain instances found in $WORKDIR."
    return 0
  fi

  local recs=() f email dn idx dname st proxy
  for f in "${metas[@]}"; do
    email="$(meta_get "$f" email)"
    dn="$(meta_get "$f" device_num)"
    idx="$(meta_get "$f" idx)"
    dname="$(meta_get "$f" device_name)"
    proxy="$(meta_get "$f" proxy)"
    st="$(instance_status "$idx")"
    recs+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$email" "$dn" "$idx" "$dname" "$st" "$proxy")")
  done

  local sorted
  sorted="$(printf '%s\n' "${recs[@]}" | sort -t$'\t' -k1,1 -k2,2n)"

  echo "Honeygain instances (WORKDIR=$WORKDIR):"
  echo
  local cur=""
  while IFS=$'\t' read -r email dn idx dname st proxy; do
    [[ -z "$email" ]] && continue
    if [[ "$email" != "$cur" ]]; then
      cur="$email"
      echo "Account: $email"
      printf '  %-7s %-22s %-8s %-5s %s\n' "device" "name" "status" "idx" "proxy"
    fi
    printf '  %-7s %-22s %-8s %-5s %s\n' "$dn" "$dname" "$st" "$idx" "$proxy"
  done <<< "$sorted"
}

unique_emails() {
  shopt -s nullglob
  local f metas=("$WORKDIR"/inst_*.meta)
  shopt -u nullglob
  (( ${#metas[@]} > 0 )) || return 0
  for f in "${metas[@]}"; do meta_get "$f" email; done | sort -u
}

stop_by_idx() {
  local idx="$1"
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "Bad idx: $idx"; return 1; }
  echo "Stopping idx $idx..."
  teardown_instance "$idx"
}

stop_account() {
  local email="$1"
  shopt -s nullglob
  local f idx metas=("$WORKDIR"/inst_*.meta)
  shopt -u nullglob
  local stopped=0
  for f in "${metas[@]}"; do
    [[ "$(meta_get "$f" email)" == "$email" ]] || continue
    idx="$(meta_get "$f" idx)"
    echo "Stopping $email (idx $idx)..."
    teardown_instance "$idx"
    stopped=$((stopped+1))
  done
  echo "Stopped $stopped instance(s) for $email."
}

stop_account_devices() {
  local email="$1" spec="$2"
  local wanted
  wanted="$(expand_device_spec "$spec" | sort -un)"
  if [[ "$wanted" == "all" ]]; then stop_account "$email"; return; fi

  shopt -s nullglob
  local f dn idx metas=("$WORKDIR"/inst_*.meta)
  shopt -u nullglob
  local stopped=0
  for f in "${metas[@]}"; do
    [[ "$(meta_get "$f" email)" == "$email" ]] || continue
    dn="$(meta_get "$f" device_num)"
    if grep -qx "$dn" <<< "$wanted"; then
      idx="$(meta_get "$f" idx)"
      echo "Stopping $email device $dn (idx $idx)..."
      teardown_instance "$idx"
      stopped=$((stopped+1))
    fi
  done
  echo "Stopped $stopped device(s) for $email."
}

stop_all() {
  local idx count=0
  for idx in $(all_indices); do
    teardown_instance "$idx"
    count=$((count+1))
  done
  echo "Stopped $count Honeygain instance(s)."
}

interactive_stop() {
  # Recover the terminal in case something left it in raw mode.
  stty sane </dev/tty 2>/dev/null || true

  local emails=()
  local e
  while IFS= read -r e; do [[ -n "$e" ]] && emails+=("$e"); done < <(unique_emails)

  if (( ${#emails[@]} == 0 )); then
    echo "No Honeygain instances found in $WORKDIR."
    return 0
  fi

  echo "Select a Honeygain account to manage:"
  local i
  for i in "${!emails[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${emails[$i]}"
  done
  echo "  a) ALL accounts (stop everything)"
  echo "  q) cancel"

  local choice
  read -rp "Choice: " choice
  case "$choice" in
    q|Q|"") echo "Cancelled."; return 0 ;;
    a|A)
      read -rp "Stop ALL instances across ALL accounts? [y/N]: " c
      if [[ "$c" =~ ^[Yy]$ ]]; then stop_all; else echo "Cancelled."; fi
      return 0 ;;
  esac

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Invalid choice."
    return 1
  fi

  local email="${emails[$((choice-1))]}"
  echo
  echo "Devices for $email:"
  local dn idx st f
  shopt -s nullglob
  local metas=("$WORKDIR"/inst_*.meta)
  shopt -u nullglob
  while IFS=$'\t' read -r dn idx; do
    st="$(instance_status "$idx")"
    printf '  device %-4s (idx %-4s) %s\n' "$dn" "$idx" "$st"
  done < <(
    for f in "${metas[@]}"; do
      [[ "$(meta_get "$f" email)" == "$email" ]] || continue
      printf '%s\t%s\n' "$(meta_get "$f" device_num)" "$(meta_get "$f" idx)"
    done | sort -k1,1n
  )

  echo
  echo "Enter devices to stop:  1   |   1,3,5   |   2-4   |   all"
  local spec
  read -rp "Devices: " spec
  [[ -z "$spec" ]] && { echo "Nothing entered. Cancelled."; return 0; }

  read -rp "Confirm stop [$spec] for $email? [y/N]: " c
  [[ "$c" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 0; }

  if [[ "$spec" == "all" ]]; then
    stop_account "$email"
  else
    stop_account_devices "$email" "$spec"
  fi
}

cmd_stop() {
  local a1="${1:-}" a2="${2:-}"
  if [[ -z "$a1" ]]; then
    interactive_stop
    return
  fi
  case "$a1" in
    all)
      stop_all ;;
    idx)
      shift
      (( $# > 0 )) || { echo "Usage: $0 stop idx <N> [N...]"; return 1; }
      local i
      for i in "$@"; do stop_by_idx "$i"; done ;;
    *)
      if [[ -z "$a2" ]]; then
        stop_account "$a1"
      else
        stop_account_devices "$a1" "$a2"
      fi ;;
  esac
}

usage() {
  cat <<EOF
Usage:
  $0 [proxies.txt]              Start Honeygain instances (default)
  $0 run [proxies.txt]          Same as above
  $0 list                       List instances grouped by account (with status)
  $0 stop                       Interactive: pick an account, then device(s)
  $0 stop all                   Stop every instance
  $0 stop <email>               Stop all devices for one account
  $0 stop <email> <devices>     Stop specific devices: 1  |  1,3,5  |  2-4
  $0 stop idx <N> [N...]        Stop specific instance index(es)

Env: BASE_NS, VETH_PREFIX, WORKDIR must match the running deployment
     (defaults: honeyns / honey / /tmp/honeygain_multi).
EOF
}

# ---------------------------------------------------------------------------
# Run mode
# ---------------------------------------------------------------------------
main() {
  PROXY_FILE="${1:-proxies.txt}"

  require_root
  save_terminal

  # Signal handlers (run mode only). INT/TERM -> exit -> EXIT trap -> cleanup.
  trap cleanup EXIT
  trap 'echo; echo "Interrupted. Cleaning up..."; exit 130' INT
  trap 'echo; echo "Terminated. Cleaning up..."; exit 143' TERM

  # Load honeygain shared libs if bundled alongside the binary.
  [[ -f app/honeygain_file/libhg.so.2.0.0 ]] && cp -f app/honeygain_file/libhg.so.2.0.0 /usr/lib/ 2>/dev/null || true
  [[ -f app/honeygain_file/libmsquic.so.2 ]] && cp -f app/honeygain_file/libmsquic.so.2 /usr/lib/ 2>/dev/null || true

  load_honeygain_accounts
  setup_nat_once
  [[ -f "$PROXY_FILE" ]] || { echo "Proxy file not found: $PROXY_FILE"; exit 1; }

  mapfile -t proxies < <(grep -vE '^\s*$|^\s*#' "$PROXY_FILE" | tr -d '\r')
  (( ${#proxies[@]} > 0 )) || { echo "No proxies in $PROXY_FILE"; exit 1; }

  local max_devices=$(( ${#HONEYGAIN_ACCOUNTS[@]} * DEVICES_PER_ACCOUNT ))
  echo "Loaded ${#proxies[@]} proxies from $PROXY_FILE"
  echo "Loaded ${#HONEYGAIN_ACCOUNTS[@]} Honeygain account(s); capacity=${max_devices} devices"

  local used=0
  local i=0
  local proxy res account_idx device_num email password account_entry
  for proxy in "${proxies[@]}"; do
    i=$((i+1))

    if (( used >= max_devices )); then
      echo "Reached Honeygain capacity (${max_devices} devices across ${#HONEYGAIN_ACCOUNTS[@]} account(s)). Remaining proxies are skipped."
      break
    fi

    if [[ "$CHECK_WORKING" == "1" ]]; then
      res="$(check_proxy "$proxy" || true)"
      if [[ "$res" == FAIL* ]]; then
        echo "[src#$i] dead: $proxy"
        continue
      fi
      if [[ "$res" == SLOW* ]]; then
        echo "[src#$i] too slow ($res): $proxy"
        continue
      fi
      echo "[src#$i] ok ($res): $proxy"
    fi

    used=$((used+1))
    account_idx=$(( (used - 1) / DEVICES_PER_ACCOUNT ))
    device_num=$(( (used - 1) % DEVICES_PER_ACCOUNT + 1 ))
    account_entry="${HONEYGAIN_ACCOUNTS[$account_idx]}"
    email="${account_entry%%|*}"
    password="${account_entry#*|}"

    start_tun2socks_and_honeygain "$used" "$proxy" "$email" "$password" "$device_num"
  done

  (( used > 0 )) || { echo "No usable proxies after filtering."; exit 1; }

  echo
  echo "Started $used Honeygain device(s). Logs:"
  echo "  $WORKDIR/honeygain_*.log"
  echo "  $WORKDIR/tun2socks_*.log"
  echo "Manage while running (from any root shell):"
  echo "  sudo WORKDIR=$WORKDIR BASE_NS=$BASE_NS VETH_PREFIX=$VETH_PREFIX bash $0 list"
  echo "  sudo WORKDIR=$WORKDIR BASE_NS=$BASE_NS VETH_PREFIX=$VETH_PREFIX bash $0 stop"
  echo "Press Ctrl+C to stop everything and clean up."

  # Wait until every instance has exited (interruptible by Ctrl+C).
  while true; do
    local running=0
    for f in "$WORKDIR"/honeygain_*.pid "$WORKDIR"/tun2socks_*.pid; do
      [[ -f "$f" ]] || continue
      local pid
      pid="$(cat "$f" 2>/dev/null)" || continue
      if kill -0 "$pid" 2>/dev/null; then
        running=1
        break
      fi
    done
    [[ "$running" == "1" ]] || break
    sleep 1
  done

  echo "All processes exited."
}

# ---------------------------------------------------------------------------
# Entry point / subcommand dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  list|ls|status)
    require_root_light; set +e; cmd_list; exit 0 ;;
  stop)
    shift; require_root_light; set +e; cmd_stop "$@"; exit 0 ;;
  help|-h|--help)
    usage; exit 0 ;;
  run)
    shift; main "$@" ;;
  *)
    main "$@" ;;
esac
