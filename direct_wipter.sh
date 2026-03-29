#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WIPTER_EMAIL="${WIPTER_EMAIL:-}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-}"
if [[ -z "$WIPTER_EMAIL" ]]; then read -rp "Enter Wipter email: " WIPTER_EMAIL; fi
if [[ -z "$WIPTER_PASSWORD" ]]; then read -rsp "Enter Wipter password: " WIPTER_PASSWORD; echo; fi
APP_NAME="wipter" \
BASE_NS="wipterns" \
WORKDIR="${WORKDIR:-/tmp/wipter_multi}" \
APP_CMD="WIPTER_EMAIL='$WIPTER_EMAIL' WIPTER_PASSWORD='$WIPTER_PASSWORD' bash ./app/wipter/wipter.sh" \
"$BASE_DIR/direct_expressvpn_runner.sh"
