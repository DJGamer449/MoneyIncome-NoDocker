#!/usr/bin/env bash
set -euo pipefail
APP_CMD_TEMPLATE='cd "$(cd "$(dirname "$0")" && pwd)" && ./app/provider provide'
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-urn}"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
