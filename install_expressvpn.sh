#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo ./install_expressvpn.sh"
  exit 1
fi

apt update
apt install -y curl iproute2 iptables jq util-linux

if [[ ! -x /opt/expressvpn/bin/expressvpnctl || ! -x /opt/expressvpn/bin/expressvpn-daemon ]]; then
  echo "ExpressVPN binaries are expected at /opt/expressvpn/bin."
  echo "Install ExpressVPN first from the official package, then rerun this manager."
  exit 1
fi

echo "ExpressVPN binaries found:"
echo " - /opt/expressvpn/bin/expressvpnctl"
echo " - /opt/expressvpn/bin/expressvpn-daemon"
