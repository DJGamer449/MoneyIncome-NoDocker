#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/app/expressvpn/script/expressvpn_netns_lib.sh"
APP_NAME="mysterium"
APP_CMD="myst service --agreed-terms-and-conditions"
run_app_instances
