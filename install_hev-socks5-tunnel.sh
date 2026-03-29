#!/usr/bin/env bash
set -euo pipefail

echo "Installing ExpressVPN runtime prerequisites only (hev-socks5-tunnel removed)."
sudo apt update
sudo apt install -y curl iproute2 iptables mount

if [[ -d ./app/expressvpn/bin ]]; then
  chmod +x ./app/expressvpn/bin/* || true
fi

echo "Done. ExpressVPN binaries are expected in ./app/expressvpn/bin"
