#!/usr/bin/env bash
set -euo pipefail
APP_NAME="urnetwork"
APP_CMD="./app/provider provide"
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-urnv}"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
