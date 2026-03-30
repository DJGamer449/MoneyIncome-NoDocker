#!/usr/bin/env bash
set -euo pipefail
APP_NAME="urnetwork"
APP_CMD="./app/provider provide"
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-ur}"
WORKDIR="${WORKDIR:-/tmp/urnetwork_multi}"
export APP_NAME APP_CMD BASE_NS VETH_PREFIX WORKDIR
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh"
