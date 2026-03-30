#!/usr/bin/env bash
set -euo pipefail
APP_NAME="traff"
BASE_NS="traffns"
VETH_PREFIX="traff"
read -rp "Enter Traff token: " TRAFF_TOKEN
APP_RUN_CMD="exec ./app/cli start accept --token '${TRAFF_TOKEN}'"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh" "$@"
