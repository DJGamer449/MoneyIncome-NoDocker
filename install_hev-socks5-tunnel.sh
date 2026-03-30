#!/usr/bin/env bash
set -euo pipefail

echo "Preparing ExpressVPN runtime dependencies..."
sudo apt-get update
sudo apt-get install -y iproute2 iptables net-tools curl jq socat util-linux

echo "ExpressVPN binaries are expected in ./app/expressvpn/bin"
if [[ ! -x ./app/expressvpn/bin/expressvpnctl ]]; then
  echo "Missing ./app/expressvpn/bin/expressvpnctl"
  exit 1
fi

echo "Dependency installation complete."
