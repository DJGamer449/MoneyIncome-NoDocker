#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="urnetwork" \
APP_CMD="./app/provider provide" \
BASE_NS="urns" \
VETH_PREFIX="urn" \
WORKDIR="${WORKDIR:-/tmp/urnetwork_runtime}" \
INSTANCE_COUNT="${INSTANCE_COUNT:-1}" \
EXPRESSVPN_CODE="${EXPRESSVPN_CODE:?Set EXPRESSVPN_CODE}" \
bash "$BASE_DIR/expressvpn_netns_runner.sh"
