#!/usr/bin/env bash
set -euo pipefail
APP_NAME="wipter"
BASE_NS="wipterns"
VETH_PREFIX="wipter"
APP_RUN_CMD='cd ./app/wipter && exec bash ./wipter.sh'
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh" "$@"
