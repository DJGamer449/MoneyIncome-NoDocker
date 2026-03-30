#!/usr/bin/env bash
set -euo pipefail
HONEYGAIN_EMAIL="${HONEYGAIN_EMAIL:-}"
HONEYGAIN_PASSWORD="${HONEYGAIN_PASSWORD:-}"
[[ -n "$HONEYGAIN_EMAIL" && -n "$HONEYGAIN_PASSWORD" ]] || { echo "HONEYGAIN_EMAIL and HONEYGAIN_PASSWORD are required"; exit 1; }
source "$(dirname "$0")/app/expressvpn/script/expressvpn_netns_lib.sh"
APP_NAME="honeygain"
APP_CMD="export LD_LIBRARY_PATH='./app/honeygain_file'; ./app/honeygain_file/honeygain -tou-accept -email '$HONEYGAIN_EMAIL' -pass '$HONEYGAIN_PASSWORD' -device 'hg-$RANDOM'"
run_app_instances
