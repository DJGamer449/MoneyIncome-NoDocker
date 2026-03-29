#!/usr/bin/env bash
set -euo pipefail
APP_NAME="earnapp"
APP_CMD="/usr/bin/earnapp run"
BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earnv}"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
