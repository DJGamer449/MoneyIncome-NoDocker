#!/usr/bin/env bash
set -euo pipefail
HONEYGAIN_EMAIL="${HONEYGAIN_EMAIL:-}"
HONEYGAIN_PASSWORD="${HONEYGAIN_PASSWORD:-}"
[[ -n "$HONEYGAIN_EMAIL" && -n "$HONEYGAIN_PASSWORD" ]] || { echo "Set HONEYGAIN_EMAIL and HONEYGAIN_PASSWORD"; exit 1; }
APP_NAME="honeygain"
APP_CMD="./app/honeygain_file/honeygain -tou-accept -email '$HONEYGAIN_EMAIL' -pass '$HONEYGAIN_PASSWORD' -device honey-\$(hostname)"
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honeyv}"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
