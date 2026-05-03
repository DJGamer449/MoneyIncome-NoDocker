#!/usr/bin/env bash
set -euo pipefail

URL="https://github.com/xjasonlyu/tun2socks/releases/download/v2.6.0/tun2socks-linux-amd64.zip"

sudo apt update
sudo apt install -y unzip curl iproute2 iptables jq

cd /tmp
curl -L -o tun2socks.zip "$URL"
unzip -o tun2socks.zip

echo "Extracted files:"
ls -lah

# Try common names
BIN=""
for c in tun2socks-linux-amd64 tun2socks; do
  if [[ -f "$c" ]]; then
    BIN="$c"
    break
  fi
done

if [[ -z "$BIN" ]]; then
  echo "Could not find tun2socks binary in zip."
  echo "Check the extracted filename above and update this script accordingly."
  exit 1
fi

sudo install -m 0755 "$BIN" /usr/local/bin/tun2socks

echo
echo "Installed tun2socks:"
command -v tun2socks
tun2socks -h || true
