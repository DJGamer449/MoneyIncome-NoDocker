#!/usr/bin/env bash
set -euo pipefail

TOKEN="${TRAFF_TOKEN:-nblQB8tNIf6aj1Hs51/SJXqflMy0x1jPnsT6kVcYB8s=}"
APP_NAME="traff"
BASE_NS="${BASE_NS:-traffns}"
VETH_PREFIX="${VETH_PREFIX:-traff}"
WORKDIR="${WORKDIR:-/tmp/traff_multi}"
APP_LAUNCH_CMD="./app/cli start accept --token '${TOKEN}'"

export APP_NAME BASE_NS VETH_PREFIX WORKDIR APP_LAUNCH_CMD
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/expressvpn_namespace_runner.sh" "$@"
