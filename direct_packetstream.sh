#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${PS_TOKEN:?Set PS_TOKEN before running PacketStream.}"
exec "$BASE_DIR/expressvpn_instance_runner.sh" packetstream "env CID='$PS_TOKEN' PS_IS_DOCKER=true app/psclient"
