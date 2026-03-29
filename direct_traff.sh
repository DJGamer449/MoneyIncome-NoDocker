#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${TRAFF_TOKEN:?Set TRAFF_TOKEN before running Traff.}"
exec "$BASE_DIR/expressvpn_instance_runner.sh" traff "app/cli --token '$TRAFF_TOKEN'"
