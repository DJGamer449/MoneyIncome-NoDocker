#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$BASE_DIR/app/expressvpn/bin"
echo "Expecting ExpressVPN binaries in: $BIN_DIR"
[[ -x "$BIN_DIR/expressvpn-daemon" ]] || { echo "Missing $BIN_DIR/expressvpn-daemon"; exit 1; }
[[ -x "$BIN_DIR/expressvpnctl" ]] || { echo "Missing $BIN_DIR/expressvpnctl"; exit 1; }
echo "ExpressVPN binaries detected."
