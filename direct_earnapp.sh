#!/usr/bin/env bash
set -euo pipefail
APP_NAME="earnapp"
BASE_NS="earnns"
VETH_PREFIX="earn"
APP_RUN_CMD='/usr/bin/earnapp start >/dev/null 2>&1 || true; exec /usr/bin/earnapp run'
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh" "$@"
