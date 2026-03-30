#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WIPTER_EMAIL="${WIPTER_EMAIL:-}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-}"
[[ -n "$WIPTER_EMAIL" && -n "$WIPTER_PASSWORD" ]] || { echo "Set WIPTER_EMAIL and WIPTER_PASSWORD"; exit 1; }
APP_NAME="wipter" \
APP_CMD="cd ./app/wipter && WIPTER_EMAIL='$WIPTER_EMAIL' WIPTER_PASSWORD='$WIPTER_PASSWORD' bash ./wipter.sh" \
BASE_NS="wipterns" \
VETH_PREFIX="wipter" \
WORKDIR="${WORKDIR:-/tmp/wipter_runtime}" \
INSTANCE_COUNT="${INSTANCE_COUNT:-1}" \
EXPRESSVPN_CODE="${EXPRESSVPN_CODE:?Set EXPRESSVPN_CODE}" \
bash "$BASE_DIR/expressvpn_netns_runner.sh"
