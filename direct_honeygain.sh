#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "direct_honeygain.sh is now managed by ExpressVPN orchestration in main.sh."
echo "Legacy proxy-file/hev-socks5-tunnel flow was removed as unnecessary."
echo "If you passed proxies.txt, it is intentionally ignored now."
exec "$BASE_DIR/main.sh" "H"
