#!/usr/bin/env bash

set -euo pipefail

# Fix CRLF
for f in "$(dirname "$0")"/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

chmod +x ./app/cli ./app/psclient ./app/provider

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

# ===============================
# KERNEL OVERCLOCK / HARDEN
# ===============================

kernel_tune() {
  echo "Applying EXTREME high-scale kernel tuning (10k instance target)..."

  # ==============================
  # FILE DESCRIPTORS
  # ==============================
  ulimit -n 2097152 || true
  sysctl -w fs.file-max=10000000 >/dev/null
  sysctl -w fs.nr_open=10000000 >/dev/null

  # ==============================
  # PORT CAPACITY (CRITICAL)
  # ==============================
  sysctl -w net.ipv4.ip_local_port_range="1000 65535" >/dev/null
  sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null
  sysctl -w net.ipv4.tcp_fin_timeout=5 >/dev/null
  sysctl -w net.ipv4.tcp_max_tw_buckets=5000000 >/dev/null

  # ==============================
  # CONNECTION TRACKING (HUGE)
  # ==============================
  sysctl -w net.netfilter.nf_conntrack_max=2097152 >/dev/null
  sysctl -w net.netfilter.nf_conntrack_buckets=524288 >/dev/null
  sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=600 >/dev/null
  sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=15 >/dev/null

  # ==============================
  # NETWORK STACK DEPTH
  # ==============================
  sysctl -w net.core.somaxconn=65535 >/dev/null
  sysctl -w net.core.netdev_max_backlog=262144 >/dev/null
  sysctl -w net.core.rmem_max=67108864 >/dev/null
  sysctl -w net.core.wmem_max=67108864 >/dev/null
  sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432" >/dev/null
  sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432" >/dev/null

  # ==============================
  # VM / MAP LIMITS
  # ==============================
  sysctl -w vm.max_map_count=1048576 >/dev/null
  sysctl -w vm.swappiness=10 >/dev/null

  # ==============================
  # ENABLE BBR (THROUGHPUT BOOST)
  # ==============================
  modprobe tcp_bbr 2>/dev/null || true
  sysctl -w net.core.default_qdisc=fq >/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

  echo "EXTREME kernel tuning applied. Hardware is now the only limit."
}


# ===============================
# CLEANUP
# ===============================

cleanup() {
  [[ "$EXITING" == "1" ]] && return
  EXITING=1
  echo -e "\nStopping all running services..."
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  echo "All services stopped."
  exit 0
}
trap cleanup INT

# ===============================
# TOKEN INPUT
# ===============================

ask_tokens() {
  echo "========== TOKEN SETUP =========="
  read -rp "Enter Traff token (or leave blank): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (or leave blank): " PS_TOKEN
  read -rp "Enter Castar Key (or leave blank): " CASTAR_KEY
  echo "================================="
}

install_dependencies() {
  sudo apt update && sudo apt install -y curl wget unzip iproute2 iptables uuid-runtime jq net-tools
}

install_earnapp() {
  install_dependencies
  wget -qO- https://brightdata.com/static/earnapp/install.sh | sudo bash
}

# ===============================
# SERVICE RUNNERS
# ===============================

run_earnapp() {
  echo "Starting EarnApp..."
  sudo BASE_NS=earnns VETH_PREFIX=earn WORKDIR=/tmp/earnapp_multi \
    bash "$EARNAPP_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_traff() {
  [[ -z "$TRAFF_TOKEN" ]] && { echo "Traff token not set."; return; }
  local RUNTIME="/tmp/traff_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|--token \".*\"|--token \"$TRAFF_TOKEN\"|g" "$RUNTIME"
  echo "Starting Traff..."
  sudo BASE_NS=traffns VETH_PREFIX=traff WORKDIR=/tmp/traff_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_packetstream() {
  [[ -z "$PS_TOKEN" ]] && { echo "PacketStream token not set."; return; }
  local RUNTIME="/tmp/ps_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|APP_CMD=.*|APP_CMD=( env CID=\"$PS_TOKEN\" PS_IS_DOCKER=true ./app/psclient )|g" "$RUNTIME"
  echo "Starting PacketStream..."
  sudo BASE_NS=psns VETH_PREFIX=ps WORKDIR=/tmp/ps_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_castar() {
  [[ -z "$CASTAR_KEY" ]] && { echo "Castar key not set."; return; }
  local RUNTIME="/tmp/castar_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|APP_CMD=.*|APP_CMD=( /root/CastarSDK -key=\"$CASTAR_KEY\" )|g" "$RUNTIME"
  echo "Starting Castar..."
  sudo BASE_NS=castarns VETH_PREFIX=castar WORKDIR=/tmp/castar_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_urnetwork() {
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
  echo -e "\n====== GRAND NETWORK MANAGER ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Run UrNetwork"
  echo "5) Run Castar"
  echo "6) Install tun2socks"
  echo "7) Install EarnApp Binary"
  echo "8) Install Dependencies"
  echo "9) Run ALL (Safe Mode)"
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
    6) sudo bash "$INSTALL_SCRIPT" ;;
    7) install_earnapp ;;
    8) install_dependencies ;;
    9)
      run_earnapp; sleep 2
      run_traff; sleep 2
      run_packetstream; sleep 2
      run_urnetwork; sleep 2
      run_castar
      echo "All services running . Press Ctrl+C to stop."
      wait
      ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done
