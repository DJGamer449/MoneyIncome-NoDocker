#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$BASE_DIR/expressvpn_instance_runner.sh" mysterium "myst --ui"
