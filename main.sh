#!/usr/bin/env bash

# ===============================
# HARDENED GRAND NETWORK MANAGER
# Kernel tuning + resource scaling
# ===============================

set -euo pipefail

# Fix CRLF if needed
for f in "$(dirname "$0")"/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

# Permissions
chmod +x ./app/cli ./app/psclient ./app/provider ./app/CastarSDK ./app/antgain 2>/dev/null || true

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

EARNAPP_SCRIPT="$BASE_DIR/direct_earnapp.sh"
TRAFF_SCRIPT="$BASE_DIR/direct_traff.sh"
UR_SCRIPT="$BASE_DIR/direct_urnetwork.sh"
ANTGAIN_SCRIPT="$BASE_DIR/direct_antgain.sh"
INSTALL_SCRIPT="$BASE_DIR/install_tun2socks.sh"

PIDS=()
EXITING=0

TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
ANTGAIN_API_KEY=""

# ===============================
# KERNEL TUNING
# ===============================

kernel_tune() {
  echo "Applying EXTREME high-scale kernel tuning..."

  ulimit -n 2097152 || true
  sysctl -w fs.file-max=10000000 >/dev/null
  sysctl -w fs.nr_open=10000000 >/dev/null

  sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null
  sysctl -w net.ipv4.tcp_fin_timeout=5 >/dev/null
  sysctl -w net.ipv4.tcp_max_tw_buckets=5000000 >/dev/null

  sysctl -w net.netfilter.nf_conntrack_max=2097152 >/dev/null
  sysctl -w net.netfilter.nf_conntrack_buckets=524288 >/dev/null

  sysctl -w net.core.somaxconn=65535 >/dev/null
  sysctl -w net.core.netdev_max_backlog=262144 >/dev/null

  sysctl -w net.core.rmem_max=134217728 >/dev/null
  sysctl -w net.core.wmem_max=134217728 >/dev/null

  sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432" >/dev/null
  sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432" >/dev/null

  sysctl -w vm.max_map_count=1048576 >/dev/null
  sysctl -w vm.swappiness=10 >/dev/null

  modprobe tcp_bbr 2>/dev/null || true
  sysctl -w net.core.default_qdisc=fq >/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

  rm -f /etc/resolv.conf
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf

  echo "Kernel tuning applied."
}

cleanup() {
  [[ "$EXITING" == "1" ]] && return
  EXITING=1

  echo
  echo "Stopping all running services..."

  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done

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
  read -rp "Enter Traff token (optional): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (optional): " PS_TOKEN
  read -rp "Enter Castar Key (optional): " CASTAR_KEY
  read -rp "Enter AntGain API Key (optional): " ANTGAIN_API_KEY
  echo "================================="
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

  sed -i "s|APP_CMD=.*|APP_CMD=( ./app/CastarSDK -key=\"$CASTAR_KEY\" )|g" "$RUNTIME"

  echo "Starting Castar..."
  sudo BASE_NS=castarns VETH_PREFIX=castar WORKDIR=/tmp/castar_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_antgain() {
  [[ -z "$ANTGAIN_API_KEY" ]] && { echo "AntGain API key not set."; return; }

  echo "Starting AntGain..."

  sudo ANTGAIN_API_KEY="$ANTGAIN_API_KEY" \
    BASE_NS=antns \
    VETH_PREFIX=ant \
    WORKDIR=/tmp/antgain_multi \
    bash "$ANTGAIN_SCRIPT" proxies.txt &

  PIDS+=($!)
}

run_urnetwork() {
  echo "Starting UrNetwork..."

  if [[ ! -f "$HOME/.urnetwork/jwt" ]]; then
    ./app/provider auth
  fi

  sudo BASE_NS=urns VETH_PREFIX=ur WORKDIR=/tmp/ur_multi \
    bash "$UR_SCRIPT" proxies.txt &
  PIDS+=($!)
}

# ===============================
# MENU
# ===============================

menu() {
  echo
  echo "====== GRAND NETWORK MANAGER ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Run UrNetwork"
  echo "5) Run Castar"
  echo "6) Run AntGain"
  echo "7) Install tun2socks"
  echo "8) Run ALL"
  echo "0) Exit"
  echo "==================================="
}

# ===============================
# START
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
    6) run_antgain ; wait ;;
    7) sudo bash "$INSTALL_SCRIPT" ; wait ;;
    8)
      run_earnapp
      run_traff
      run_packetstream
      run_urnetwork
      run_castar
      run_antgain
      echo "All services running. Ctrl+C to stop."
      wait
      ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done
