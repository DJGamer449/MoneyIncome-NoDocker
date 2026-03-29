#!/usr/bin/env bash
set -euo pipefail
mkdir -p /opt/expressvpn
cp -r ./app/expressvpn/* /opt/expressvpn/
install -m 0755 ./app/expressvpn/bin/expressvpnctl /usr/local/bin/expressvpnctl
echo "ExpressVPN files installed to /opt/expressvpn and /usr/local/bin/expressvpnctl"
