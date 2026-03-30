#!/usr/bin/env bash
set -euo pipefail
CASTAR_KEY="${CASTAR_KEY:-}"
[[ -n "$CASTAR_KEY" ]] || { echo "CASTAR_KEY is required"; exit 1; }
source "$(dirname "$0")/app/expressvpn/script/expressvpn_netns_lib.sh"
APP_NAME="castar"
APP_CMD="./app/CastarSDK -key='$CASTAR_KEY'"
run_app_instances
