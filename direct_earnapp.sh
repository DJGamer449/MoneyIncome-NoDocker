#!/usr/bin/env bash
set -euo pipefail
APP_NAME="earnapp"
APP_CMD="/usr/bin/earnapp run"
BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earn}"
WORKDIR="${WORKDIR:-/tmp/earnapp_multi}"
export APP_NAME APP_CMD BASE_NS VETH_PREFIX WORKDIR
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh"
