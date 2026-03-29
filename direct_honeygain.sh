#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HG_EMAIL="${HG_EMAIL:-}"
HG_PASSWORD="${HG_PASSWORD:-}"
if [[ -z "$HG_EMAIL" ]]; then read -rp "Enter Honeygain email: " HG_EMAIL; fi
if [[ -z "$HG_PASSWORD" ]]; then read -rsp "Enter Honeygain password: " HG_PASSWORD; echo; fi
APP_NAME="honeygain" \
BASE_NS="honeyns" \
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}" \
APP_CMD="./app/honeygain_file/honeygain -tou-accept -email '$HG_EMAIL' -pass '$HG_PASSWORD' -device honey-\$(hostname)" \
"$BASE_DIR/direct_expressvpn_runner.sh"
