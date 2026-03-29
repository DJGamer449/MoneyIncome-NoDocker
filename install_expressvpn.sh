#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "Installing docker..."
  curl -fsSL https://get.docker.com | sh
fi

echo "Pulling misioslav/expressvpn image..."
docker pull misioslav/expressvpn:latest

echo "Done."
