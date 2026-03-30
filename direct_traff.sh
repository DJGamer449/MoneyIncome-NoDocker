#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN="${TRAFF_TOKEN:-${TOKEN:-}}"
[[ -n "$TOKEN" ]] || { echo "Set TRAFF_TOKEN"; exit 1; }
APP_NAME="traff" \
APP_CMD="./app/cli start accept --token '$TOKEN'" \
BASE_NS="traffns" \
VETH_PREFIX="traff" \
WORKDIR="${WORKDIR:-/tmp/traff_runtime}" \
INSTANCE_COUNT="${INSTANCE_COUNT:-1}" \
EXPRESSVPN_CODE="${EXPRESSVPN_CODE:?Set EXPRESSVPN_CODE}" \
bash "$BASE_DIR/expressvpn_netns_runner.sh"
