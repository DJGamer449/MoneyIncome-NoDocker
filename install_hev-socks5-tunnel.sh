#!/usr/bin/env bash
set -euo pipefail

echo "hev-socks5-tunnel has been replaced by ExpressVPN in this project."
exec "$(cd "$(dirname "$0")" && pwd)/install_expressvpn.sh"
