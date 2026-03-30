#!/usr/bin/env bash
set -euo pipefail
APP_NAME="castar"
BASE_NS="castarns"
VETH_PREFIX="castar"
read -rp "Enter Castar key: " CASTAR_KEY
APP_RUN_CMD="exec ./app/CastarSDK -key='${CASTAR_KEY}'"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh" "$@"
