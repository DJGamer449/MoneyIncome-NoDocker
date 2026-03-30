#!/usr/bin/env bash
set -euo pipefail
APP_CMD_TEMPLATE='earnapp start'
BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-ern}"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
