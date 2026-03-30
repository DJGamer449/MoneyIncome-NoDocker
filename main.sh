#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REGION_FILE="$BASE_DIR/expressvpn_region.txt"

TRAFF_SCRIPT="$BASE_DIR/direct_traff.sh"
EARNAPP_SCRIPT="$BASE_DIR/direct_earnapp.sh"
UR_SCRIPT="$BASE_DIR/direct_urnetwork.sh"
CASTAR_SCRIPT="$BASE_DIR/direct_castar.sh"
WIPTER_SCRIPT="$BASE_DIR/direct_wipter.sh"
HONEYGAIN_SCRIPT="$BASE_DIR/direct_honeygain.sh"
MYSTERIUM_SCRIPT="$BASE_DIR/direct_mysterium.sh"

EXPRESSVPN_CODE=""
INSTANCE_COUNT=1
TRAFF_TOKEN=""
CASTAR_KEY=""
WIPTER_EMAIL=""
WIPTER_PASSWORD=""
HONEYGAIN_EMAIL=""
HONEYGAIN_PASSWORD=""

ask_core_config() {
  echo "========== EXPRESSVPN SETUP =========="
  while [[ -z "$EXPRESSVPN_CODE" ]]; do
    read -rsp "Enter ExpressVPN activation key: " EXPRESSVPN_CODE
    echo
  done

  while true; do
    read -rp "How many instances to run per app? " INSTANCE_COUNT
    [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] && ((INSTANCE_COUNT > 0)) && break
    echo "Please input a positive integer."
  done

  echo "Instance to region mapping:"
  mapfile -t regions < <(tr -s '[:space:]' '\n' < "$REGION_FILE" | sed "s/^'//;s/'$//" | sed '/^$/d')
  for i in $(seq 1 "$INSTANCE_COUNT"); do
    idx=$(( (i - 1) % ${#regions[@]} ))
    echo "  instance-$i -> ${regions[$idx]}"
  done
  echo "======================================"
}

ask_tokens() {
  echo "========== APP TOKENS =========="
  read -rp "Traff token (optional): " TRAFF_TOKEN
  read -rp "Castar key (optional): " CASTAR_KEY
  read -rp "Wipter email (optional): " WIPTER_EMAIL
  read -rsp "Wipter password (optional): " WIPTER_PASSWORD; echo
  read -rp "Honeygain email (optional): " HONEYGAIN_EMAIL
  read -rsp "Honeygain password (optional): " HONEYGAIN_PASSWORD; echo
  echo "================================"
}

run_with_vpn() {
  local script="$1"
  shift
  sudo -E env \
    EXPRESSVPN_CODE="$EXPRESSVPN_CODE" \
    INSTANCE_COUNT="$INSTANCE_COUNT" \
    "$@" \
    bash "$script"
}

menu() {
  echo
  echo "====== EXPRESSVPN MULTI-INSTANCE MANAGER ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run UrNetwork"
  echo "4) Run Castar"
  echo "5) Run Wipter"
  echo "6) Run Honeygain"
  echo "7) Run Mysterium"
  echo "8) Run ALL"
  echo "0) Exit"
  echo "==============================================="
}

ask_core_config
ask_tokens

while true; do
  menu
  read -rp "Select option: " opt
  case "$opt" in
    1) run_with_vpn "$EARNAPP_SCRIPT" ;;
    2) run_with_vpn "$TRAFF_SCRIPT" TRAFF_TOKEN="$TRAFF_TOKEN" ;;
    3) run_with_vpn "$UR_SCRIPT" ;;
    4) run_with_vpn "$CASTAR_SCRIPT" CASTAR_KEY="$CASTAR_KEY" ;;
    5) run_with_vpn "$WIPTER_SCRIPT" WIPTER_EMAIL="$WIPTER_EMAIL" WIPTER_PASSWORD="$WIPTER_PASSWORD" ;;
    6) run_with_vpn "$HONEYGAIN_SCRIPT" HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL" HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD" ;;
    7) run_with_vpn "$MYSTERIUM_SCRIPT" ;;
    8)
      run_with_vpn "$EARNAPP_SCRIPT"
      run_with_vpn "$TRAFF_SCRIPT" TRAFF_TOKEN="$TRAFF_TOKEN"
      run_with_vpn "$UR_SCRIPT"
      run_with_vpn "$CASTAR_SCRIPT" CASTAR_KEY="$CASTAR_KEY"
      run_with_vpn "$WIPTER_SCRIPT" WIPTER_EMAIL="$WIPTER_EMAIL" WIPTER_PASSWORD="$WIPTER_PASSWORD"
      run_with_vpn "$HONEYGAIN_SCRIPT" HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL" HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD"
      run_with_vpn "$MYSTERIUM_SCRIPT"
      ;;
    0) exit 0 ;;
    *) echo "Invalid option." ;;
  esac
done
