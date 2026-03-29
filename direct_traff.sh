#!/usr/bin/env bash
set -euo pipefail
TRAFF_TOKEN="${TRAFF_TOKEN:-}"
[[ -n "$TRAFF_TOKEN" ]] || { echo "Set TRAFF_TOKEN"; exit 1; }
APP_NAME="traff"
APP_CMD="./app/cli start accept --token '$TRAFF_TOKEN'"
BASE_NS="${BASE_NS:-traffns}"
VETH_PREFIX="${VETH_PREFIX:-traffv}"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
