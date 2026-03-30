#!/usr/bin/env bash
set -euo pipefail
APP_NAME="honeygain"
APP_CMD="./app/honeygain_file/honeygain"
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
export APP_NAME APP_CMD BASE_NS VETH_PREFIX WORKDIR
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh"
