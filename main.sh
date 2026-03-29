#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$BASE_DIR/expressvpn_instance_runner.sh"
INSTALL_SCRIPT="$BASE_DIR/install_expressvpn.sh"

TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
WIPTER_EMAIL=""
WIPTER_PASSWORD=""
HONEYGAIN_EMAIL=""
HONEYGAIN_PASSWORD=""

ask_tokens() {
  echo "========== APP TOKEN SETUP =========="
  read -rp "Enter Traff token (or leave blank): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (or leave blank): " PS_TOKEN
  read -rp "Enter Castar Key (or leave blank): " CASTAR_KEY
  read -rp "Enter Wipter Email (or leave blank): " WIPTER_EMAIL
  read -rsp "Enter Wipter Password (hidden, leave blank to skip): " WIPTER_PASSWORD
  echo
  read -rp "Enter Honeygain Email (or leave blank): " HONEYGAIN_EMAIL
  read -rsp "Enter Honeygain Password (hidden, leave blank): " HONEYGAIN_PASSWORD
  echo
  echo "====================================="
}

run_app() {
  local app_name="$1"
  local app_cmd="$2"
  "$RUNNER" "$app_name" "$app_cmd"
}

stop_all() {
  if [[ -d "$BASE_DIR/runtime/expressvpn" ]]; then
    while IFS= read -r container; do
      [[ -n "$container" ]] || continue
      docker rm -f "$container" >/dev/null 2>&1 || true
    done < <(find "$BASE_DIR/runtime/expressvpn" -name containers.list -type f -exec cat {} + | sort -u)
  fi
  echo "Stopped all tracked ExpressVPN app containers."
}

menu() {
  echo -e "\n====== GRAND NETWORK MANAGER (EXPRESSVPN ISOLATED) ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Run UrNetwork"
  echo "5) Run Castar"
  echo "6) Install ExpressVPN Docker runtime"
  echo "H) Run Honeygain"
  echo "W) Run Wipter"
  echo "M) Run Mysterium Node"
  echo "S) Stop all running app instances"
  echo "0) Exit"
  echo "========================================================="
}

ask_tokens

while true; do
  menu
  read -rp "Select option: " opt
  case "$opt" in
    1)
      run_app "earnapp" "./app/cli"
      ;;
    2)
      [[ -n "$TRAFF_TOKEN" ]] || { echo "Traff token not set."; continue; }
      run_app "traff" "app/cli --token '$TRAFF_TOKEN'"
      ;;
    3)
      [[ -n "$PS_TOKEN" ]] || { echo "PacketStream token not set."; continue; }
      run_app "packetstream" "env CID='$PS_TOKEN' PS_IS_DOCKER=true ./app/psclient"
      ;;
    4)
      run_app "urnetwork" "./app/provider"
      ;;
    5)
      [[ -n "$CASTAR_KEY" ]] || { echo "Castar key not set."; continue; }
      run_app "castar" "./app/CastarSDK -key='$CASTAR_KEY'"
      ;;
    6)
      "$INSTALL_SCRIPT"
      ;;
    H|h)
      [[ -n "$HONEYGAIN_EMAIL" && -n "$HONEYGAIN_PASSWORD" ]] || { echo "Honeygain credentials not set."; continue; }
      run_app "honeygain" "./app/honeygain_file/honeygain -tou-accept -email '$HONEYGAIN_EMAIL' -pass '$HONEYGAIN_PASSWORD' -device hg-instance"
      ;;
    W|w)
      [[ -n "$WIPTER_EMAIL" && -n "$WIPTER_PASSWORD" ]] || { echo "Wipter credentials not set."; continue; }
      run_app "wipter" "./app/cli --email '$WIPTER_EMAIL' --password '$WIPTER_PASSWORD'"
      ;;
    M|m)
      run_app "mysterium" "myst --ui"
      ;;
    S|s)
      stop_all
      ;;
    0)
      exit 0
      ;;
    *)
      echo "Invalid option."
      ;;
  esac
done
