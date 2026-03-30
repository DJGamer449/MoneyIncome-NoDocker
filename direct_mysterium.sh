#!/usr/bin/env bash
set -euo pipefail
APP_NAME="mysterium"
BASE_NS="mysterns"
VETH_PREFIX="myst"
APP_RUN_CMD='exec myst --agreed-terms-and-conditions --identity.passphrase=auto'
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh" "$@"
