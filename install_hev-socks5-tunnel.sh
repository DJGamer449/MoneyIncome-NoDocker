#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPRESSVPN_DIR="$BASE_DIR/app/expressvpn"

sudo apt update
sudo apt install -y iproute2 iptables jq net-tools socat busybox

for part in bin lib share qml expressvpn-service script; do
  if [[ ! -e "$EXPRESSVPN_DIR/$part" ]]; then
    echo "Missing ExpressVPN bundle component: $EXPRESSVPN_DIR/$part"
    exit 1
  fi
done

chmod +x "$EXPRESSVPN_DIR/expressvpn-service" "$EXPRESSVPN_DIR/script"/*.sh

echo "ExpressVPN runtime bundle is present at: $EXPRESSVPN_DIR"
echo "This installer now prepares dependencies for netns-isolated ExpressVPN instances."
