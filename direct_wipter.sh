#!/usr/bin/env bash
set -euo pipefail
APP_NAME="wipter"
APP_CMD="cd ./app/wipter && ./wipter.sh"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_multi}"
export APP_NAME APP_CMD BASE_NS VETH_PREFIX WORKDIR
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh"
