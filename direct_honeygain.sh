#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EMAIL="${HONEYGAIN_EMAIL:-}"
PASSWORD="${HONEYGAIN_PASSWORD:-}"
[[ -n "$EMAIL" && -n "$PASSWORD" ]] || { echo "Set HONEYGAIN_EMAIL and HONEYGAIN_PASSWORD"; exit 1; }
APP_NAME="honeygain" \
APP_CMD="./app/honeygain_file/honeygain -tou-accept -email '$EMAIL' -pass '$PASSWORD' -device honey-$RANDOM" \
BASE_NS="honeyns" \
VETH_PREFIX="honey" \
WORKDIR="${WORKDIR:-/tmp/honeygain_runtime}" \
INSTANCE_COUNT="${INSTANCE_COUNT:-1}" \
EXPRESSVPN_CODE="${EXPRESSVPN_CODE:?Set EXPRESSVPN_CODE}" \
bash "$BASE_DIR/expressvpn_netns_runner.sh"
