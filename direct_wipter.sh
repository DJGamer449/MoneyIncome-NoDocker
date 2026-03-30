#!/usr/bin/env bash
set -euo pipefail
APP_CMD_TEMPLATE='cd "$(cd "$(dirname "$0")" && pwd)" && ./app/wipter/wipter.sh -email "${WIPTER_EMAIL:?WIPTER_EMAIL is required}" -password "${WIPTER_PASSWORD:?WIPTER_PASSWORD is required}"'
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wpt}"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
