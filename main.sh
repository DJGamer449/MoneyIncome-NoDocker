#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="$BASE_DIR/install_expressvpn.sh"

EXPRESSVPN_ACTIVATION_KEY="${EXPRESSVPN_ACTIVATION_KEY:-}"
INSTANCE_COUNT="${INSTANCE_COUNT:-}"
TRAFF_TOKEN="${TRAFF_TOKEN:-}"
PS_TOKEN="${PS_TOKEN:-}"
CASTAR_KEY="${CASTAR_KEY:-}"
WIPTER_EMAIL="${WIPTER_EMAIL:-}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-}"
HONEYGAIN_EMAIL="${HONEYGAIN_EMAIL:-}"
HONEYGAIN_PASSWORD="${HONEYGAIN_PASSWORD:-}"

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run as root: sudo ./main.sh"
    exit 1
  fi
}

prompt_shared() {
  if [[ -z "$EXPRESSVPN_ACTIVATION_KEY" ]]; then
    read -rsp "Enter ExpressVPN activation key (asked once): " EXPRESSVPN_ACTIVATION_KEY
    echo
  fi

  if [[ -z "$INSTANCE_COUNT" ]]; then
    read -rp "How many isolated instances per app? " INSTANCE_COUNT
  fi

  [[ "$INSTANCE_COUNT" =~ ^[1-9][0-9]*$ ]] || {
    echo "Instance count must be a positive integer."
    exit 1
  }
}

run_script() {
  local script="$1"
  INSTANCES="$INSTANCE_COUNT" \
  EXPRESSVPN_ACTIVATION_KEY="$EXPRESSVPN_ACTIVATION_KEY" \
  TRAFF_TOKEN="$TRAFF_TOKEN" \
  CASTAR_KEY="$CASTAR_KEY" \
  WIPTER_EMAIL="$WIPTER_EMAIL" \
  WIPTER_PASSWORD="$WIPTER_PASSWORD" \
  HONEYGAIN_EMAIL="$HONEYGAIN_EMAIL" \
  HONEYGAIN_PASSWORD="$HONEYGAIN_PASSWORD" \
  bash "$BASE_DIR/$script"
}

run_packetstream() {
  [[ -n "$PS_TOKEN" ]] || read -rp "Enter PacketStream CID: " PS_TOKEN
  INSTANCES="$INSTANCE_COUNT" EXPRESSVPN_ACTIVATION_KEY="$EXPRESSVPN_ACTIVATION_KEY" TRAFF_TOKEN="$PS_TOKEN" \
    bash "$BASE_DIR/direct_traff.sh" <<<' '
}

menu() {
  cat <<MENU

====== MoneyIncome NoDocker (ExpressVPN netns mode) ======
1) Install ExpressVPN dependencies
2) Run EarnApp through isolated ExpressVPN instances
3) Run Traff through isolated ExpressVPN instances
4) Run PacketStream through isolated ExpressVPN instances
5) Run UrNetwork through isolated ExpressVPN instances
6) Run Castar through isolated ExpressVPN instances
7) Run Honeygain through isolated ExpressVPN instances
8) Run Wipter through isolated ExpressVPN instances
9) Run Mysterium through isolated ExpressVPN instances
A) Run ALL apps through isolated ExpressVPN instances
0) Exit
==========================================================
MENU
}

need_root
while true; do
  menu
  read -rp "Select option: " opt
  case "$opt" in
    1) bash "$INSTALL_SCRIPT" ;;
    2) prompt_shared; run_script direct_earnapp.sh ;;
    3) prompt_shared; [[ -n "$TRAFF_TOKEN" ]] || read -rp "Enter Traff token: " TRAFF_TOKEN; run_script direct_traff.sh ;;
    4) prompt_shared; run_packetstream ;;
    5) prompt_shared; run_script direct_urnetwork.sh ;;
    6) prompt_shared; [[ -n "$CASTAR_KEY" ]] || read -rp "Enter Castar key: " CASTAR_KEY; run_script direct_castar.sh ;;
    7) prompt_shared; [[ -n "$HONEYGAIN_EMAIL" ]] || read -rp "Enter Honeygain email: " HONEYGAIN_EMAIL; [[ -n "$HONEYGAIN_PASSWORD" ]] || { read -rsp "Enter Honeygain password: " HONEYGAIN_PASSWORD; echo; }; run_script direct_honeygain.sh ;;
    8) prompt_shared; [[ -n "$WIPTER_EMAIL" ]] || read -rp "Enter Wipter email: " WIPTER_EMAIL; [[ -n "$WIPTER_PASSWORD" ]] || { read -rsp "Enter Wipter password: " WIPTER_PASSWORD; echo; }; run_script direct_wipter.sh ;;
    9) prompt_shared; run_script direct_mysterium.sh ;;
    A|a)
      prompt_shared
      [[ -n "$TRAFF_TOKEN" ]] || read -rp "Enter Traff token: " TRAFF_TOKEN
      [[ -n "$PS_TOKEN" ]] || read -rp "Enter PacketStream CID: " PS_TOKEN
      [[ -n "$CASTAR_KEY" ]] || read -rp "Enter Castar key: " CASTAR_KEY
      [[ -n "$HONEYGAIN_EMAIL" ]] || read -rp "Enter Honeygain email: " HONEYGAIN_EMAIL
      [[ -n "$HONEYGAIN_PASSWORD" ]] || { read -rsp "Enter Honeygain password: " HONEYGAIN_PASSWORD; echo; }
      [[ -n "$WIPTER_EMAIL" ]] || read -rp "Enter Wipter email: " WIPTER_EMAIL
      [[ -n "$WIPTER_PASSWORD" ]] || { read -rsp "Enter Wipter password: " WIPTER_PASSWORD; echo; }

      run_script direct_earnapp.sh
      run_script direct_traff.sh
      run_packetstream
      run_script direct_urnetwork.sh
      run_script direct_castar.sh
      run_script direct_honeygain.sh
      run_script direct_wipter.sh
      run_script direct_mysterium.sh
      ;;
    0) exit 0 ;;
    *) echo "Invalid option." ;;
  esac
done
