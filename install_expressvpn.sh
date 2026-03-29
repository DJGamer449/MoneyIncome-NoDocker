#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }

if [[ ! -d ./app/expressvpn ]]; then
  echo "Missing ./app/expressvpn directory"
  exit 1
fi

mkdir -p /opt/expressvpn
cp -a ./app/expressvpn/. /opt/expressvpn/

if [[ -f ./app/expressvpn/bin/expressvpnctl ]]; then
  install -m 0755 ./app/expressvpn/bin/expressvpnctl /usr/local/bin/expressvpnctl
else
  echo "Missing ./app/expressvpn/bin/expressvpnctl"
  exit 1
fi

echo "ExpressVPN files installed."
chmod +x /opt/expressvpn/start.sh 2>/dev/null || true
echo "Run with: export CODE=<activation-key>; export SERVER='<region>'; cd /opt/expressvpn && ./start.sh"
