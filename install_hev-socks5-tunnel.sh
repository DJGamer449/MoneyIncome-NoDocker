#!/usr/bin/env bash
set -euo pipefail

echo "hev-socks5-tunnel flow has been replaced by ExpressVPN."
exec "$(cd "$(dirname "$0")" && pwd)/install_expressvpn.sh"
