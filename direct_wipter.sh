#!/usr/bin/env bash
set -euo pipefail
WIPTER_EMAIL="${WIPTER_EMAIL:-}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-}"
[[ -n "$WIPTER_EMAIL" && -n "$WIPTER_PASSWORD" ]] || { echo "WIPTER_EMAIL and WIPTER_PASSWORD are required"; exit 1; }
source "$(dirname "$0")/app/expressvpn/script/expressvpn_netns_lib.sh"
APP_NAME="wipter"
APP_ENV_EXPORTS="export WIPTER_EMAIL='$WIPTER_EMAIL'; export WIPTER_PASSWORD='$WIPTER_PASSWORD'"
APP_CMD="cd ./app/wipter && bash ./wipter.sh"
run_app_instances
