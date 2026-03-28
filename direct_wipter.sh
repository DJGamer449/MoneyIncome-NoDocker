#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${WIPTER_EMAIL:-}" ]]; then
  read -r -p "Enter WIPTER_EMAIL: " WIPTER_EMAIL
fi
if [[ -z "${WIPTER_PASSWORD:-}" ]]; then
  read -r -s -p "Enter WIPTER_PASSWORD: " WIPTER_PASSWORD
  echo
fi
[[ -n "${WIPTER_EMAIL:-}" && -n "${WIPTER_PASSWORD:-}" ]] || { echo "WIPTER_EMAIL and WIPTER_PASSWORD are required"; exit 1; }

APP_NAME="wipter"
BASE_NS="${BASE_NS:-wipterns}"
VETH_PREFIX="${VETH_PREFIX:-wipter}"
WORKDIR="${WORKDIR:-/tmp/wipter_multi}"
APP_LAUNCH_CMD="cd ./app/wipter && WIPTER_EMAIL='${WIPTER_EMAIL}' WIPTER_PASSWORD='${WIPTER_PASSWORD}' bash ./wipter.sh"

export APP_NAME BASE_NS VETH_PREFIX WORKDIR APP_LAUNCH_CMD
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/expressvpn_namespace_runner.sh" "$@"
