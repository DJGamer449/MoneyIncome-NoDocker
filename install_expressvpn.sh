#!/usr/bin/env bash
set -euo pipefail
sudo apt update
sudo apt install -y iproute2 iptables util-linux curl jq
echo "ExpressVPN runtime dependencies installed."
echo "Place ExpressVPN bundle under ./app/expressvpn (bin/lib/share/etc + expressvpn-service + script)."
