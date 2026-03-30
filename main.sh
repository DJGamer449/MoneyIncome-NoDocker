#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPRESSVPN_CODE=""
INSTANCE_COUNT="1"
TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
WIPTER_EMAIL=""
WIPTER_PASSWORD=""
HONEYGAIN_EMAIL=""
HONEYGAIN_PASSWORD=""

ask_required_inputs() {
  echo "========== EXPRESSVPN SETUP =========="
  while [[ -z "$EXPRESSVPN_CODE" ]]; do
    read -rsp "Enter ExpressVPN activation key: " EXPRESSVPN_CODE
    echo
  done
  while true; do
    read -rp "How many instances to run per app? " INSTANCE_COUNT
    [[ "$INSTANCE_COUNT" =~ ^[1-9][0-9]*$ ]] && break
    echo "Please enter a positive integer."
  done
  echo "======================================"
}

ask_optional_inputs() {
  read -rp "Traff token (optional): " TRAFF_TOKEN
  read -rp "PacketStream CID (optional): " PS_TOKEN
  read -rp "Castar key (optional): " CASTAR_KEY
  read -rp "Wipter email (optional): " WIPTER_EMAIL
  read -rsp "Wipter password (optional): " WIPTER_PASSWORD
  echo
  read -rp "Honeygain email (optional): " HONEYGAIN_EMAIL
  read -rsp "Honeygain password (optional): " HONEYGAIN_PASSWORD
  echo
}

run_script() {
  local script="$1"
  shift || true
  sudo env EXPRESSVPN_CODE="$EXPRESSVPN_CODE" INSTANCE_COUNT="$INSTANCE_COUNT" "$@" bash "$script"
}

run_packetstream() {
  [[ -n "$PS_TOKEN" ]] || { echo "PacketStream token missing"; return; }
  APP_NAME="packetstream" APP_CMD="env CID='$PS_TOKEN' PS_IS_DOCKER=true ./app/psclient" \
  BASE_NS="psns" VETH_PREFIX="ps" WORKDIR="/tmp/ps_runtime" \
  run_script "$BASE_DIR/expressvpn_netns_runner.sh"
}

menu() {
  echo
  echo "====== NETWORK MANAGER (EXPRESSVPN NETNS) ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Run UrNetwork"
  echo "5) Run Castar"
  echo "6) Run Honeygain"
  echo "7) Run Wipter"
  echo "8) Run Mysterium"
  echo "9) Run ALL"
  echo "0) Exit"
  echo "==============================================="
}

ask_required_inputs
ask_optional_inputs

while true; do
  menu
  read -rp "Select option: " opt
  case "$opt" in
    1) run_script "$BASE_DIR/direct_earnapp.sh" ;;
    2) run_script "$BASE_DIR/direct_traff.sh" TRAFF_TOKEN="$TRAFF_TOKEN" ;;
    3) run_packetstream ;;
    4) run_script "$BASE_DIR/direct_urnetwork.sh" ;;
    5) run_script "$BASE_DIR/direct_castar.sh" CASTAR_KEY="$CASTAR_KEY" ;;
    6) run_script "$BASE_DIR/direct_honeygain.sh" HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL" HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD" ;;
    7) run_script "$BASE_DIR/direct_wipter.sh" WIPTER_EMAIL="$WIPTER_EMAIL" WIPTER_PASSWORD="$WIPTER_PASSWORD" ;;
    8) run_script "$BASE_DIR/direct_mysterium.sh" ;;
    9)
      run_script "$BASE_DIR/direct_earnapp.sh" &
      run_script "$BASE_DIR/direct_urnetwork.sh" &
      [[ -n "$TRAFF_TOKEN" ]] && run_script "$BASE_DIR/direct_traff.sh" TRAFF_TOKEN="$TRAFF_TOKEN" &
      [[ -n "$CASTAR_KEY" ]] && run_script "$BASE_DIR/direct_castar.sh" CASTAR_KEY="$CASTAR_KEY" &
      [[ -n "$HONEYGAIN_EMAIL" && -n "$HONEYGAIN_PASSWORD" ]] && run_script "$BASE_DIR/direct_honeygain.sh" HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL" HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD" &
      [[ -n "$WIPTER_EMAIL" && -n "$WIPTER_PASSWORD" ]] && run_script "$BASE_DIR/direct_wipter.sh" WIPTER_EMAIL="$WIPTER_EMAIL" WIPTER_PASSWORD="$WIPTER_PASSWORD" &
      run_script "$BASE_DIR/direct_mysterium.sh" &
      [[ -n "$PS_TOKEN" ]] && run_packetstream &
      wait
      ;;
    0) exit 0 ;;
    *) echo "Invalid option" ;;
  esac
done
