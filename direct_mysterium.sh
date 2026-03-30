#!/usr/bin/env bash
set -euo pipefail
APP_CMD_TEMPLATE='myst service --agreed-terms-and-conditions --data-dir "/tmp/myst-%s"'
BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-mys}"
source "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
