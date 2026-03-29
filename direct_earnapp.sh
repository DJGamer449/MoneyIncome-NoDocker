#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="earnapp" \
BASE_NS="earnns" \
WORKDIR="${WORKDIR:-/tmp/earnapp_multi}" \
APP_CMD="/usr/bin/earnapp run" \
"$BASE_DIR/direct_expressvpn_runner.sh"
