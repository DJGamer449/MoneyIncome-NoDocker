#!/usr/bin/env bash
set -euo pipefail

APP_NAME="mysterium"
BASE_NS="${BASE_NS:-mysterns}"
VETH_PREFIX="${VETH_PREFIX:-myster}"
WORKDIR="${WORKDIR:-/tmp/mysterium_multi}"
MYST_BIN="${MYST_BIN:-$(command -v myst || true)}"
[[ -n "${MYST_BIN}" ]] || { echo "myst binary not found in PATH"; exit 1; }
APP_LAUNCH_CMD="'${MYST_BIN}' service --agreed-terms-and-conditions"

export APP_NAME BASE_NS VETH_PREFIX WORKDIR APP_LAUNCH_CMD
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/expressvpn_namespace_runner.sh" "$@"
