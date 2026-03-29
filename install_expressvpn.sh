#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$BASE_DIR/app/expressvpn"
DST_DIR="/opt/expressvpn"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Missing source directory: $SRC_DIR"
  exit 1
fi

sudo mkdir -p "$DST_DIR"
sudo cp -a "$SRC_DIR"/. "$DST_DIR"/
sudo install -m 0755 "$SRC_DIR/bin/expressvpnctl" /usr/local/bin/expressvpnctl
sudo chmod +x "$DST_DIR/start.sh"

echo "ExpressVPN runtime installed to $DST_DIR"
echo "Control binary: /usr/local/bin/expressvpnctl"
echo "Usage: export CODE=<activation-code>; export SERVER=<region>; /opt/expressvpn/start.sh"
