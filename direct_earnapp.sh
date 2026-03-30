#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="earnapp" \
APP_CMD="earnapp start" \
BASE_NS="earnns" \
VETH_PREFIX="earn" \
WORKDIR="${WORKDIR:-/tmp/earnapp_runtime}" \
INSTANCE_COUNT="${INSTANCE_COUNT:-1}" \
EXPRESSVPN_CODE="${EXPRESSVPN_CODE:?Set EXPRESSVPN_CODE}" \
bash "$BASE_DIR/expressvpn_netns_runner.sh"
