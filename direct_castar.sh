#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CASTAR_KEY="${CASTAR_KEY:-}"
if [[ -z "$CASTAR_KEY" ]]; then
  read -rp "Enter Castar key: " CASTAR_KEY
fi
APP_NAME="castar" \
BASE_NS="castarns" \
WORKDIR="${WORKDIR:-/tmp/castar_multi}" \
APP_CMD="./app/CastarSDK -k '$CASTAR_KEY'" \
"$BASE_DIR/direct_expressvpn_runner.sh"
