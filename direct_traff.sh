#!/usr/bin/env bash
set -euo pipefail
APP_NAME="traff"
APP_CMD="./app/cli start accept --token '${TRAFF_TOKEN:-}'"
BASE_NS="${BASE_NS:-traffns}"
VETH_PREFIX="${VETH_PREFIX:-traff}"
WORKDIR="${WORKDIR:-/tmp/traff_multi}"
export APP_NAME APP_CMD BASE_NS VETH_PREFIX WORKDIR
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh"
