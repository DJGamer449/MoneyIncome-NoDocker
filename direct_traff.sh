#!/usr/bin/env bash
set -euo pipefail
PROFILE="${APP_PROFILE:-traff}"
TOKEN="${APP_TOKEN:-}"
case "$PROFILE" in
  traff)
    [[ -n "$TOKEN" ]] || { echo "APP_TOKEN is required for Traff"; exit 1; }
    APP_NAME="traff"
    APP_CMD="./app/cli --token '$TOKEN'"
    ;;
  packetstream)
    [[ -n "$TOKEN" ]] || { echo "APP_TOKEN is required for PacketStream CID"; exit 1; }
    APP_NAME="packetstream"
    APP_CMD="env CID='$TOKEN' PS_IS_DOCKER=true ./app/psclient"
    ;;
  *) echo "Unsupported APP_PROFILE=$PROFILE"; exit 1;;
esac
source "$(dirname "$0")/app/expressvpn/script/expressvpn_netns_lib.sh"
run_app_instances
