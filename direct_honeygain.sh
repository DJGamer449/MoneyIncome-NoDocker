#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${HONEYGAIN_EMAIL:-}" ]]; then
  read -r -p "Enter HONEYGAIN_EMAIL: " HONEYGAIN_EMAIL
fi
if [[ -z "${HONEYGAIN_PASSWORD:-}" ]]; then
  read -r -s -p "Enter HONEYGAIN_PASSWORD: " HONEYGAIN_PASSWORD
  echo
fi
[[ -n "${HONEYGAIN_EMAIL:-}" && -n "${HONEYGAIN_PASSWORD:-}" ]] || { echo "HONEYGAIN_EMAIL and HONEYGAIN_PASSWORD are required"; exit 1; }

APP_NAME="honeygain"
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
APP_LAUNCH_CMD="./app/honeygain_file/honeygain -tou-accept -email '${HONEYGAIN_EMAIL}' -pass '${HONEYGAIN_PASSWORD}' -device 'honey-{INDEX}'"

export APP_NAME BASE_NS VETH_PREFIX WORKDIR APP_LAUNCH_CMD
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/expressvpn_namespace_runner.sh" "$@"
