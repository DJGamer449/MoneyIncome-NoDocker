#!/usr/bin/env bash
set -euo pipefail
PS_TOKEN="${PS_TOKEN:-}"
[[ -n "$PS_TOKEN" ]] || { echo "Set PS_TOKEN"; exit 1; }
APP_NAME="packetstream"
APP_CMD="env CID='$PS_TOKEN' PS_IS_DOCKER=true ./app/psclient"
BASE_NS="${BASE_NS:-psns}"
VETH_PREFIX="${VETH_PREFIX:-psv}"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
