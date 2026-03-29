#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
PS_TOKEN="${PS_TOKEN:-}"
if [[ -z "$PS_TOKEN" ]]; then
  read -rp "Enter PacketStream CID token: " PS_TOKEN
fi
APP_NAME="packetstream" \
BASE_NS="psns" \
WORKDIR="${WORKDIR:-/tmp/ps_multi}" \
APP_CMD="CID='$PS_TOKEN' PS_IS_DOCKER=true ./app/psclient" \
"$BASE_DIR/direct_expressvpn_runner.sh"
