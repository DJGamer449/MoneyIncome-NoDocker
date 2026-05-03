#!/usr/bin/env bash
set -euo pipefail

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ASSET="hev-socks5-tunnel-linux-x86_64" ;;
  aarch64|arm64) ASSET="hev-socks5-tunnel-linux-arm64" ;;
  *)
    echo "Unsupported architecture: $ARCH"
    echo "Choose a compatible asset from: https://github.com/heiher/hev-socks5-tunnel/releases/latest"
    exit 1
    ;;
esac

TAG="$(curl -fsSL https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest | jq -r .tag_name)"
URL="https://github.com/heiher/hev-socks5-tunnel/releases/download/${TAG}/${ASSET}"

sudo apt update
sudo apt install -y curl iproute2 iptables jq

cd /tmp
curl -fL -o hev-socks5-tunnel "$URL"
chmod +x hev-socks5-tunnel
sudo install -m 0755 hev-socks5-tunnel /usr/local/bin/hev-socks5-tunnel

echo
echo "Installed hev-socks5-tunnel:"
command -v hev-socks5-tunnel
