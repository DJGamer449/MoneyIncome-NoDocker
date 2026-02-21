#!/usr/bin/env bash
for f in "$(dirname "$0")"/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done
set -euo pipefail
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
CASTAR_KEY="" #

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
  read -rp "Enter Castar Key (or leave blank): " CASTAR_KEY #
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
  sed -i "s|APP_CMD=.*|APP_CMD=( env CID=\"$PS_TOKEN\" PS_IS_DOCKER=true ./app/psclient )|g" "$RUNTIME_PS"
  echo "Starting PacketStream..."
  sudo BASE_NS=psns VETH_PREFIX=ps WORKDIR=/tmp/ps_multi \
    bash "$RUNTIME_PS" proxies.txt &
  PIDS+=($!)
}

# --- New Castar Function ---
run_castar() {
  [[ -z "$CASTAR_KEY" ]] && { echo "Castar key not set."; return; }
  local RUNTIME_CASTAR="/tmp/castar_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME_CASTAR"
  # Replaces the APP_CMD in direct_traff.sh with the Castar binary and your key
  sed -i "s|APP_CMD=.*|APP_CMD=( ./app/CastarSDK -key=\"$CASTAR_KEY\" )|g" "$RUNTIME_CASTAR"
  echo "Starting Castar..."
  sudo BASE_NS=castarns VETH_PREFIX=castar WORKDIR=/tmp/castar_multi \
    bash "$RUNTIME_CASTAR" proxies.txt &
  PIDS+=($!)
}

run_urnetwork() {
  echo "Starting UrNetwork..."

  # Check if JWT already exists
  if [[ -f "$HOME/.urnetwork/jwt" ]]; then
    echo "UrNetwork JWT detected. Skipping auth setup..."
  else
    echo "No UrNetwork JWT found. Running first-time authentication..."
    ./provider auth
    echo "Authentication complete."
  fi

  sudo BASE_NS=urns VETH_PREFIX=ur WORKDIR=/tmp/ur_multi \
    bash "$UR_SCRIPT" proxies.txt &
  PIDS+=($!)
}

menu() {
  echo -e "\n====== GRAND NETWORK MANAGER ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Run UrNetwork"
  echo "5) Run Castar"  # Added
  echo "6) Install tun2socks"
  echo "7) Install EarnApp Binary"
  echo "8) Install Dependencies"
  echo "9) Run ALL"
  echo "0) Exit"
  echo "===================================="
}

ask_tokens
while true; do
  menu
  read -rp "Select option: " opt || cleanup
  case "$opt" in
    1) run_earnapp ; wait ;;
    2) run_traff ; wait ;;
    3) run_packetstream ; wait ;;
    4) run_urnetwork ; wait ;;
    5) run_castar ; wait ;; #
    6) sudo bash "$INSTALL_SCRIPT" ;;
    7) install_earnapp ;;
    8) install_dependencies ;;
    9) run_earnapp; sleep 2; run_traff; sleep 2; run_packetstream; sleep 2; run_urnetwork; sleep 2; run_castar; echo "All services running. Press Ctrl+C to stop."; wait ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done
