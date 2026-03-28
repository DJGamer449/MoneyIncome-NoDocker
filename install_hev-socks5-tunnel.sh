#!/usr/bin/env bash
set -euo pipefail

echo "hev-socks5-tunnel has been replaced with ExpressVPN in this project."
echo "Place ExpressVPN CLI binaries under: ./app/expressvpn/bin/"
echo "Required executable: ./app/expressvpn/bin/expressvpnctl"

if [[ -x ./app/expressvpn/bin/expressvpnctl ]]; then
  echo
  echo "expressvpnctl detected:"
  ./app/expressvpn/bin/expressvpnctl --help | head -n 30 || true
else
  echo
  echo "expressvpnctl not found yet."
  echo "After installing, run main.sh and provide your ExpressVPN key/token when prompted."
fi
