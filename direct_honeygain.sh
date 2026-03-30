#!/usr/bin/env bash
set -euo pipefail
APP_NAME="honeygain"
BASE_NS="honeyns"
VETH_PREFIX="honey"
read -rp "Enter Honeygain email: " HG_EMAIL
read -rsp "Enter Honeygain password: " HG_PASS
echo
APP_RUN_CMD="exec ./app/honeygain_file/honeygain -tou-accept -email '${HG_EMAIL}' -pass '${HG_PASS}' -device 'hg-'\$(hostname)-\$(date +%s)"
exec "$(cd "$(dirname "$0")" && pwd)/direct_expressvpn_runner.sh" "$@"
