#!/usr/bin/env bash
set -euo pipefail
MYST_BIN="${MYST_BIN:-$(command -v myst || true)}"
[[ -n "$MYST_BIN" ]] || { echo "myst binary not found"; exit 1; }
APP_NAME="mysterium"
APP_CMD="$MYST_BIN service --agreed-terms-and-conditions"
BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-mystv}"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_common.sh"
