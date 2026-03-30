#!/usr/bin/env bash
set -euo pipefail
APP_NAME="mysterium"
APP_CMD="myst service --agreed-terms-and-conditions"
BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-myst}"
WORKDIR="${WORKDIR:-/tmp/mysterium_multi}"
export APP_NAME APP_CMD BASE_NS VETH_PREFIX WORKDIR
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh"
