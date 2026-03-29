#!/usr/bin/env bash
set -euo pipefail
CASTAR_KEY="${CASTAR_KEY:-}"
[[ -n "$CASTAR_KEY" ]] || { echo "Set CASTAR_KEY"; exit 1; }
APP_NAME="castar"
APP_CMD="./app/CastarSDK -key='$CASTAR_KEY'"
BASE_NS="${BASE_NS:-castarns}"
VETH_PREFIX="${VETH_PREFIX:-castv}"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
