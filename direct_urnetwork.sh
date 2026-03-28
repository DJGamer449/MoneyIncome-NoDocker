#!/usr/bin/env bash
set -euo pipefail

APP_NAME="urnetwork"
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-ur}"
WORKDIR="${WORKDIR:-/tmp/ur_multi}"
APP_LAUNCH_CMD="./app/provider provide"

export APP_NAME BASE_NS VETH_PREFIX WORKDIR APP_LAUNCH_CMD
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/expressvpn_namespace_runner.sh" "$@"
