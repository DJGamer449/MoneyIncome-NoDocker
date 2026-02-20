#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EARNAPP_SCRIPT="$BASE_DIR/direct_earnapp.sh"
TRAFF_SCRIPT="$BASE_DIR/direct_traff.sh"
INSTALL_SCRIPT="$BASE_DIR/install_tun2socks.sh"

PIDS=()
EXITING=0

cleanup() {
  [[ "$EXITING" == "1" ]] && return
  EXITING=1

  echo
  echo "Ctrl+C detected. Stopping all running services..."

  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done

  wait 2>/dev/null || true

  echo "All services stopped."
  exit 0
}

trap cleanup INT

run_earnapp() {
  echo "Starting EarnApp..."
  sudo BASE_NS=earnns WORKDIR=/tmp/earnapp_multi \
    bash "$EARNAPP_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_traff() {
  read -rp "Enter Traff token: " TOKEN

  cp "$TRAFF_SCRIPT" /tmp/direct_traff_runtime.sh
  sed -i "s|--token \".*\"|--token \"$TOKEN\"|g" /tmp/direct_traff_runtime.sh

  echo "Starting Traff..."
  sudo BASE_NS=traffns WORKDIR=/tmp/traff_multi \
    bash /tmp/direct_traff_runtime.sh proxies.txt &
  PIDS+=($!)
}

run_packetstream() {
  read -rp "Enter PacketStream CID token: " TOKEN

  cp "$TRAFF_SCRIPT" /tmp/direct_ps_runtime.sh
  sed -i "s|APP_CMD=.*|APP_CMD=( env CID=\"$TOKEN\" PS_IS_DOCKER=true ./psclient )|g" \
    /tmp/direct_ps_runtime.sh

  echo "Starting PacketStream..."
  sudo BASE_NS=psns WORKDIR=/tmp/ps_multi \
    bash /tmp/direct_ps_runtime.sh proxies.txt &
  PIDS+=($!)
}

install_tun() {
  sudo bash "$INSTALL_SCRIPT"
}

menu() {
  echo
  echo "====== GRAND NETWORK MANAGER ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Install tun2socks"
  echo "5) Run ALL"
  echo "0) Exit"
  echo "===================================="
}

while true; do
  menu
  read -rp "Select option: " opt || cleanup

  case "$opt" in
    1) run_earnapp ;;
    2) run_traff ;;
    3) run_packetstream ;;
    4) install_tun ;;
    5)
       run_earnapp
       run_traff
       run_packetstream
       ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done
