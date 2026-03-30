#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/app/expressvpn/bin"
[[ -d "$SRC_DIR" ]] || { echo "Missing $SRC_DIR"; exit 1; }

sudo mkdir -p /usr/local/bin
sudo cp -a "$SRC_DIR"/. /usr/local/bin/
sudo chmod +x /usr/local/bin/expressvpn* 2>/dev/null || true

echo "Installed ExpressVPN binaries from local bundle: $SRC_DIR"
command -v expressvpn || true
