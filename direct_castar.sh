#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${CASTAR_KEY:-}" ]]; then
  read -r -p "Enter CASTAR_KEY: " CASTAR_KEY
fi
[[ -n "${CASTAR_KEY:-}" ]] || { echo "CASTAR_KEY is required"; exit 1; }

APP_NAME="castar"
BASE_NS="${BASE_NS:-castarns}"
VETH_PREFIX="${VETH_PREFIX:-castar}"
WORKDIR="${WORKDIR:-/tmp/castar_multi}"
APP_LAUNCH_CMD="./app/CastarSDK -key='${CASTAR_KEY}'"

export APP_NAME BASE_NS VETH_PREFIX WORKDIR APP_LAUNCH_CMD
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/expressvpn_namespace_runner.sh" "$@"
