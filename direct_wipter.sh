#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${WIPTER_EMAIL:?Set WIPTER_EMAIL.}"
: "${WIPTER_PASSWORD:?Set WIPTER_PASSWORD.}"
exec "$BASE_DIR/expressvpn_instance_runner.sh" wipter "app/cli --email '$WIPTER_EMAIL' --password '$WIPTER_PASSWORD'"
