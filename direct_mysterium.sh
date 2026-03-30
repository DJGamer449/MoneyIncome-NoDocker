#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="mysterium" \
APP_CMD="myst --agreed-terms-and-conditions service --data-dir /tmp/myst-data" \
BASE_NS="mysterns" \
VETH_PREFIX="myster" \
WORKDIR="${WORKDIR:-/tmp/mysterium_runtime}" \
INSTANCE_COUNT="${INSTANCE_COUNT:-1}" \
EXPRESSVPN_CODE="${EXPRESSVPN_CODE:?Set EXPRESSVPN_CODE}" \
bash "$BASE_DIR/expressvpn_netns_runner.sh"
