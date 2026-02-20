#!/usr/bin/env bash
for f in "$(dirname "$0")"/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done
set -euo pipefail
chmod +x ./cli ./psclient
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EARNAPP_SCRIPT="$BASE_DIR/direct_earnapp.sh"
TRAFF_SCRIPT="$BASE_DIR/direct_traff.sh"
INSTALL_SCRIPT="$BASE_DIR/install_tun2socks.sh"

PIDS=()
EXITING=0
TRAFF_TOKEN=""
PS_TOKEN=""

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

ask_tokens() {
  echo "========== TOKEN SETUP =========="
  read -rp "Enter Traff token (or leave blank): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (or leave blank): " PS_TOKEN
  echo "================================="
}

install_dependencies() {
  sudo apt update && sudo apt install -y curl wget unzip iproute2 iptables uuid-runtime jq net-tools
}

install_earnapp() {
  install_dependencies
  wget -qO- https://brightdata.com/static/earnapp/install.sh | sudo bash
}

run_earnapp() {
  echo "Starting EarnApp..."
  sudo BASE_NS=earnns VETH_PREFIX=earn WORKDIR=/tmp/earnapp_multi \
    bash "$EARNAPP_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_traff() {
  [[ -z "$TRAFF_TOKEN" ]] && { echo "Traff token not set."; return; }
  local RUNTIME_TRAFF="/tmp/traff_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME_TRAFF"
  sed -i "s|--token \".*\"|--token \"$TRAFF_TOKEN\"|g" "$RUNTIME_TRAFF"
  echo "Starting Traff..."
  sudo BASE_NS=traffns VETH_PREFIX=traff WORKDIR=/tmp/traff_multi \
    bash "$RUNTIME_TRAFF" proxies.txt &
  PIDS+=($!)
}

run_packetstream() {
  [[ -z "$PS_TOKEN" ]] && { echo "PacketStream token not set."; return; }
  local RUNTIME_PS="/tmp/ps_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME_PS"
  sed -i "s|APP_CMD=.*|APP_CMD=( env CID=\"$PS_TOKEN\" PS_IS_DOCKER=true ./psclient )|g" "$RUNTIME_PS"
  echo "Starting PacketStream..."
  sudo BASE_NS=psns VETH_PREFIX=ps WORKDIR=/tmp/ps_multi \
    bash "$RUNTIME_PS" proxies.txt &
  PIDS+=($!)
}

menu() {
  echo -e "\n====== GRAND NETWORK MANAGER ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Install tun2socks"
  echo "5) Install EarnApp Binary"
  echo "6) Install Dependencies"
  echo "7) Run ALL"
  echo "0) Exit"
  echo "===================================="
}

ask_tokens
while true; do
  menu
  read -rp "Select option: " opt || cleanup
  case "$opt" in
    1) run_earnapp ;;
    2) run_traff ;;
    3) run_packetstream ;;
    4) sudo bash "$INSTALL_SCRIPT" ;;
    5) install_earnapp ;;
    6) install_dependencies ;;
    7) run_earnapp; sleep 2; run_traff; sleep 2; run_packetstream ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done