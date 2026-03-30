#!/usr/bin/env bash
set -euo pipefail
APP_CMD_TEMPLATE='cd "$(cd "$(dirname "$0")" && pwd)" && ./app/honeygain_file/honeygain -tou-accept -email "${HONEYGAIN_EMAIL:?HONEYGAIN_EMAIL is required}" -pass "${HONEYGAIN_PASSWORD:?HONEYGAIN_PASSWORD is required}" -device "hg-%s"'
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-hny}"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
