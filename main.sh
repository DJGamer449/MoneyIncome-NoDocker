#!/usr/bin/env bash

# ===============================
# HARDENED GRAND NETWORK MANAGER (MULTI-APP SAFE)
# Kernel tuning + per-namespace network isolation + clone-and-run helper
# ===============================

set -euo pipefail

# Fix CRLF if needed
for f in "$(dirname "$0")"/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

chmod +x ./app/cli ./app/psclient ./app/provider ./app/CastarSDK 2>/dev/null || true

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EARNAPP_SCRIPT="$BASE_DIR/direct_earnapp.sh"
TRAFF_SCRIPT="$BASE_DIR/direct_traff.sh"
UR_SCRIPT="$BASE_DIR/direct_urnetwork.sh"
INSTALL_SCRIPT="$BASE_DIR/install_tun2socks.sh"

PIDS=()
EXITING=0
TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""

# maps ns name -> numeric index used for subnet allocation
declare -A NS_INDEX=(
  [earnns]=1
  [traffns]=2
  [psns]=3
  [castarns]=4
  [urns]=5
)

# store created namespaces for cleanup
CREATED_NETNS=()
# store iptables rules we added (subnets) for cleanup
CREATED_SUBNETS=()

# detect host default interface for NAT
HOST_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[ -n "$HOST_IF" ] || HOST_IF="eth0"  # fallback

# ===============================
# KERNEL TUNE (conservative & safer)
# ===============================
kernel_tune() {
  echo "Applying conservative kernel tuning for high-scale (safe defaults)..."

  # FILE DESCRIPTORS
  sudo modprobe nf_conntrack 2>/dev/null || true
  ulimit -n 2097152 || true
  sudo sysctl -w fs.file-max=1000000 >/dev/null || true
  sudo sysctl -w fs.nr_open=2000000 >/dev/null || true

  # TCP tweaks (conservative)
  sudo sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_fin_timeout=30 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_max_tw_buckets=200000 >/dev/null || true

  # connection tracking (raise but not insane)
  sudo sysctl -w net.netfilter.nf_conntrack_max=262144 >/dev/null || true
  sudo sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=600 >/dev/null || true

  # network stack
  sudo sysctl -w net.core.somaxconn=65535 >/dev/null || true
  sudo sysctl -w net.core.netdev_max_backlog=262144 >/dev/null || true
  sudo sysctl -w net.core.rmem_max=67108864 >/dev/null || true
  sudo sysctl -w net.core.wmem_max=67108864 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432" >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432" >/dev/null || true

  # VM limits
  sudo sysctl -w vm.max_map_count=262144 >/dev/null || true
  sudo sysctl -w vm.swappiness=10 >/dev/null || true

  # enable ip forwarding for NAT (required for per-namespace internet)
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null || true

  # enable BBR if available
  sudo modprobe tcp_bbr 2>/dev/null || true
  sudo sysctl -w net.core.default_qdisc=fq >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || true

  # IMPORTANT: Do NOT overwrite global /etc/resolv.conf here.
  # We'll provide per-namespace resolv.conf files so starting multiple services won't break host DNS.
  echo "Kernel tuning applied (conservative)."
}

# ===============================
# Create network namespace + veth pair + NAT
# each ns gets a /24 10.200.<index>.0/24
# host veth IP = 10.200.<index>.1
# ns veth IP   = 10.200.<index>.2
# ===============================
create_netns_with_veth() {
  local ns="$1"
  local veth_prefix="${2:-veth}"
  local idx="${3:-0}"

  # derive idx automatically if not provided
  if [ "$idx" -eq 0 ]; then
    idx="${NS_INDEX[$ns]:-0}"
    if [ -z "$idx" ] || [ "$idx" -eq 0 ]; then
      # pick a free index (starting 10)
      idx=10
      while ip netns list | grep -qw "ns${idx}"; do
        idx=$((idx+1))
      done
    fi
  fi

  # skip if exists
  if ip netns list | awk '{print $1}' | grep -qw "$ns"; then
    echo "Netns $ns already exists, skipping creation."
    return 0
  fi

  echo "Creating netns $ns with veth prefix ${veth_prefix} idx ${idx}..."

  sudo ip netns add "$ns"
  CREATED_NETNS+=("$ns")

  local host_if="${veth_prefix}h${idx}"
  local ns_if="${veth_prefix}n${idx}"
  local host_ip="10.200.${idx}.1/24"
  local ns_ip="10.200.${idx}.2/24"
  local subnet="10.200.${idx}.0/24"

  # create veth pair
  sudo ip link add "$host_if" type veth peer name "$ns_if"
  # move ns side to namespace
  sudo ip link set "$ns_if" netns "$ns"

  # configure host side
  sudo ip addr add "$host_ip" dev "$host_if" || true
  sudo ip link set "$host_if" up

  # configure ns side
  sudo ip netns exec "$ns" ip addr add "$ns_ip" dev "$ns_if"
  sudo ip netns exec "$ns" ip link set "$ns_if" up
  sudo ip netns exec "$ns" ip link set lo up
  sudo ip netns exec "$ns" ip route add default via "10.200.${idx}.1" || true

  # set per-namespace resolv.conf (so DNS inside ns works and host DNS remains untouched)
  sudo mkdir -p "/etc/netns/$ns"
  echo "nameserver 1.1.1.1" | sudo tee /etc/netns/"$ns"/resolv.conf >/dev/null
  echo "nameserver 8.8.8.8" | sudo tee -a /etc/netns/"$ns"/resolv.conf >/dev/null

  # NAT for that subnet to the host default interface
  sudo iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
  CREATED_SUBNETS+=("$subnet")

  echo "Netns $ns created: host dev $host_if ($host_ip) <-> ns dev $ns_if ($ns_ip)."
}

# ===============================
# Cleanup
# ===============================
cleanup() {
  [[ "$EXITING" == "1" ]] && return
  EXITING=1
  echo -e "\nStopping all running services..."

  # kill backgrounded PIDs
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true

  # remove iptables NAT rules we added
  for subnet in "${CREATED_SUBNETS[@]:-}"; do
    sudo iptables -t nat -D POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || true
  done

  # remove namespaces
  for ns in "${CREATED_NETNS[@]:-}"; do
    sudo ip netns delete "$ns" 2>/dev/null || true
    sudo rm -rf /etc/netns/"$ns" 2>/dev/null || true
  done

  echo "All services and network namespaces stopped/removed."
  exit 0
}
trap cleanup INT TERM

# ===============================
# Token Input (unchanged)
# ===============================
ask_tokens() {
  echo "========== TOKEN SETUP =========="
  read -rp "Enter Traff token (or leave blank): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (or leave blank): " PS_TOKEN
  read -rp "Enter Castar Key (or leave blank): " CASTAR_KEY
  echo "================================="
}

install_dependencies() {
  sudo apt update && sudo apt install -y curl wget unzip iproute2 iptables uuid-runtime jq net-tools git
}

install_earnapp() {
  install_dependencies
  wget -qO- https://brightdata.com/static/earnapp/install.sh > /tmp/earnapp.sh && sudo bash /tmp/earnapp.sh
}

# ===============================
# Utilities to clone arbitrary repo and run inside its own namespace
# Example:
#   clone_and_run "https://github.com/me/app.git" "app" "./start.sh" \
#       -> clones to /opt/apps/app and runs /opt/apps/app/start.sh inside namespace "appns"
# ===============================
clone_and_run() {
  local repo_url="$1"
  local app_name="$2"
  local run_cmd="$3"    # command relative to repo dir to run, e.g. "./start.sh arg1"
  local ns_name="${4:-${app_name}ns}"
  local veth_prefix="${5:-${app_name}_veth}"
  local idx="${6:-0}"

  local dest="/opt/apps/$app_name"

  sudo mkdir -p /opt/apps
  if [ ! -d "$dest/.git" ]; then
    echo "Cloning $repo_url -> $dest"
    sudo git clone "$repo_url" "$dest"
    sudo chown -R "$(id -u):$(id -g)" "$dest"
  else
    echo "Repo exists at $dest; pulling latest"
    (cd "$dest" && git pull) || true
  fi

  # ensure namespace exists (creates if missing)
  create_netns_with_veth "$ns_name" "$veth_prefix" "$idx"

  echo "Starting $app_name inside namespace $ns_name..."
  # run the app inside the namespace; we run via sudo so namespace permissions are OK
  sudo ip netns exec "$ns_name" bash -lc "cd '$dest' && nohup $run_cmd >/tmp/${app_name}.log 2>&1 & echo \$!" \
    | { read -r pid; echo "$pid"; PIDS+=("$pid"); } >/dev/null 2>&1 || true

  echo "$app_name started (check /tmp/${app_name}.log in namespace context)."
}

# ===============================
# SERVICE RUNNERS (adapted to ensure corresponding netns exists)
# ===============================
run_earnapp() {
  create_netns_with_veth "earnns" "earn" "${NS_INDEX[earnns]}"
  echo "Starting EarnApp..."
  sudo BASE_NS=earnns VETH_PREFIX=earn WORKDIR=/tmp/earnapp_multi \
    bash "$EARNAPP_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_traff() {
  if [[ -z "$TRAFF_TOKEN" ]]; then echo "Traff token not set."; return; fi
  create_netns_with_veth "traffns" "traff" "${NS_INDEX[traffns]}"
  local RUNTIME="/tmp/traff_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|--token \".*\"|--token \"$TRAFF_TOKEN\"|g" "$RUNTIME"
  echo "Starting Traff..."
  sudo BASE_NS=traffns VETH_PREFIX=traff WORKDIR=/tmp/traff_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_packetstream() {
  if [[ -z "$PS_TOKEN" ]]; then echo "PacketStream token not set."; return; fi
  create_netns_with_veth "psns" "ps" "${NS_INDEX[psns]}"
  local RUNTIME="/tmp/ps_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|APP_CMD=.*|APP_CMD=( env CID=\"$PS_TOKEN\" PS_IS_DOCKER=true ./app/psclient )|g" "$RUNTIME"
  echo "Starting PacketStream..."
  sudo BASE_NS=psns VETH_PREFIX=ps WORKDIR=/tmp/ps_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_castar() {
  if [[ -z "$CASTAR_KEY" ]]; then echo "Castar key not set."; return; fi
  create_netns_with_veth "castarns" "castar" "${NS_INDEX[castarns]}"
  local RUNTIME="/tmp/castar_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|APP_CMD=.*|APP_CMD=( ./app/CastarSDK -key=\"$CASTAR_KEY\" )|g" "$RUNTIME"
  echo "Starting Castar..."
  sudo BASE_NS=castarns VETH_PREFIX=castar WORKDIR=/tmp/castar_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_urnetwork() {
  create_netns_with_veth "urns" "ur" "${NS_INDEX[urns]}"
  echo "Starting UrNetwork..."
  if [[ ! -f "$HOME/.urnetwork/jwt" ]]; then
    ./provider auth
  fi
  sudo BASE_NS=urns VETH_PREFIX=ur WORKDIR=/tmp/ur_multi \
    bash "$UR_SCRIPT" proxies.txt &
  PIDS+=($!)
}

# ===============================
# MENU
# ===============================
menu() {
  echo -e "\n====== GRAND NETWORK MANAGER (HARDENED / MULTI-NS) ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Run UrNetwork"
  echo "5) Run Castar"
  echo "6) Install tun2socks"
  echo "7) Install EarnApp Binary"
  echo "8) Install Dependencies"
  echo "9) Run ALL (Safe Mode)"
  echo "A) Clone & Run custom repo"
  echo "0) Exit"
  echo "==============================================="
}

# ===============================
# STARTUP
# ===============================
kernel_tune
ask_tokens

while true; do
  menu
  read -rp "Select option: " opt || cleanup
  case "$opt" in
    1) run_earnapp ; wait ;;
    2) run_traff ; wait ;;
    3) run_packetstream ; wait ;;
    4) run_urnetwork ; wait ;;
    5) run_castar ; wait ;;
    6) sudo bash "$INSTALL_SCRIPT" ; wait ;;
    7) install_earnapp ; wait ;;
    8) install_dependencies ; wait ;;
    9)
      run_earnapp
      run_traff
      run_packetstream
      run_urnetwork
      run_castar
      echo "All services running (staggered safe mode). Press Ctrl+C to stop."
      wait
      ;;
    A|a)
      read -rp "Repo URL: " repo
      read -rp "App name (short): " aname
      read -rp "Run command (relative to repo root, e.g. ./start.sh): " runcmd
      clone_and_run "$repo" "$aname" "$runcmd"
      ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done
