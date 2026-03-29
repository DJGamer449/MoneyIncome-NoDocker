#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${CASTAR_KEY:?Set CASTAR_KEY before running Castar.}"
exec "$BASE_DIR/expressvpn_instance_runner.sh" castar "app/CastarSDK -key='$CASTAR_KEY'"
