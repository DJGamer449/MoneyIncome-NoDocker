#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE_DIR/app/expressvpn/bin"
DEST="/opt/expressvpn/bin"

if [[ ! -d "$SRC" ]]; then
  echo "Missing ExpressVPN binaries in $SRC"
  exit 1
fi

sudo mkdir -p "$DEST"
sudo cp -a "$SRC/." "$DEST/"
sudo chmod +x "$DEST/expressvpn-daemon" "$DEST/expressvpnctl" 2>/dev/null || true

echo "ExpressVPN runtime installed at $DEST"
