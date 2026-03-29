#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
TRAFF_TOKEN="${TRAFF_TOKEN:-}"
if [[ -z "$TRAFF_TOKEN" ]]; then
  read -rp "Enter Traff token: " TRAFF_TOKEN
fi
APP_NAME="traff" \
BASE_NS="traffns" \
WORKDIR="${WORKDIR:-/tmp/traff_multi}" \
APP_CMD="./app/cli --device-name traff --token '$TRAFF_TOKEN'" \
"$BASE_DIR/direct_expressvpn_runner.sh"
