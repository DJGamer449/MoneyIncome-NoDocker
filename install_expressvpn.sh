#!/usr/bin/env bash
set -euo pipefail

echo "Installing base packages required for ExpressVPN workflows..."
sudo apt update
sudo apt install -y curl wget iproute2 iptables ca-certificates gnupg lsb-release

echo "Done."
echo "Install/upgrade ExpressVPN app manually in your environment, then ensure expressvpnctl exists at:"
echo "  ./app/expressvpn/bin/expressvpnctl"
echo "or in PATH."
