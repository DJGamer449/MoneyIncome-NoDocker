#!/usr/bin/env bash
set -euo pipefail
APP_NAME="wipter"
APP_CMD="cd ./app/wipter && ./wipter.sh"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wiptv}"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
