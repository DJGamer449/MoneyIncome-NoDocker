#!/usr/bin/env bash
set -euo pipefail

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) TARGET_ARCH="x86_64" ;;
  aarch64|arm64) TARGET_ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $ARCH"
    echo "Install manually from https://github.com/heiher/hev-socks5-tunnel/releases"
    exit 1
    ;;
esac

REPO="heiher/hev-socks5-tunnel"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

sudo apt update
sudo apt install -y curl iproute2 iptables jq

TAG="$(curl -fsSL "$API_URL" | jq -r '.tag_name')"
URL="https://github.com/${REPO}/releases/download/${TAG}/hev-socks5-tunnel-linux-${TARGET_ARCH}"

TMP_BIN="/tmp/hev-socks5-tunnel"
curl -fL "$URL" -o "$TMP_BIN"
chmod +x "$TMP_BIN"
sudo install -m 0755 "$TMP_BIN" /usr/local/bin/hev-socks5-tunnel

echo
echo "Installed hev-socks5-tunnel:"
command -v hev-socks5-tunnel
hev-socks5-tunnel -h || true
