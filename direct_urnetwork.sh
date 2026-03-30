#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/app/expressvpn/script/expressvpn_netns_lib.sh"
APP_NAME="urnetwork"
APP_CMD="./app/provider"
run_app_instances
