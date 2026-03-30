#!/usr/bin/env bash
set -euo pipefail
APP_NAME="urnetwork"
BASE_NS="urns"
VETH_PREFIX="ur"
APP_RUN_CMD='exec ./app/provider provide'
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh" "$@"
