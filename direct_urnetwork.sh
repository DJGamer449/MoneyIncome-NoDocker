#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="urnetwork" \
BASE_NS="urns" \
WORKDIR="${WORKDIR:-/tmp/urnetwork_multi}" \
APP_CMD="./app/provider" \
"$BASE_DIR/direct_expressvpn_runner.sh"
