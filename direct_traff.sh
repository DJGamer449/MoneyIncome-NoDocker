#!/usr/bin/env bash
set -euo pipefail
APP_CMD_TEMPLATE='cd "$(cd "$(dirname "$0")" && pwd)" && ./app/cli start accept --token "${TRAFF_TOKEN:?TRAFF_TOKEN is required}"'
BASE_NS="${BASE_NS:-traffns}"
VETH_PREFIX="${VETH_PREFIX:-trf}"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
