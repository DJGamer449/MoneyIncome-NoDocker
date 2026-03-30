#!/usr/bin/env bash
set -euo pipefail
APP_NAME="castar"
APP_CMD="./app/CastarSDK -key='${CASTAR_KEY:-}'"
BASE_NS="${BASE_NS:-castarns}"
VETH_PREFIX="${VETH_PREFIX:-castar}"
WORKDIR="${WORKDIR:-/tmp/castar_multi}"
export APP_NAME APP_CMD BASE_NS VETH_PREFIX WORKDIR
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh"
