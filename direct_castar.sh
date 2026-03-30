#!/usr/bin/env bash
set -euo pipefail
APP_CMD_TEMPLATE='cd "$(cd "$(dirname "$0")" && pwd)" && ./app/CastarSDK -key="${CASTAR_KEY:?CASTAR_KEY is required}"'
BASE_NS="${BASE_NS:-castarns}"
VETH_PREFIX="${VETH_PREFIX:-csr}"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
