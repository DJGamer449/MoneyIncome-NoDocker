#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CASTAR_KEY="${CASTAR_KEY:-}"
[[ -n "$CASTAR_KEY" ]] || { echo "Set CASTAR_KEY"; exit 1; }
APP_NAME="castar" \
APP_CMD="./app/CastarSDK -key='$CASTAR_KEY'" \
BASE_NS="castarns" \
VETH_PREFIX="castar" \
WORKDIR="${WORKDIR:-/tmp/castar_runtime}" \
INSTANCE_COUNT="${INSTANCE_COUNT:-1}" \
EXPRESSVPN_CODE="${EXPRESSVPN_CODE:?Set EXPRESSVPN_CODE}" \
bash "$BASE_DIR/expressvpn_netns_runner.sh"
