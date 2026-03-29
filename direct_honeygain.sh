#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${HONEYGAIN_EMAIL:?Set HONEYGAIN_EMAIL.}"
: "${HONEYGAIN_PASSWORD:?Set HONEYGAIN_PASSWORD.}"
exec "$BASE_DIR/expressvpn_instance_runner.sh" honeygain "app/honeygain_file/honeygain -tou-accept -email '$HONEYGAIN_EMAIL' -pass '$HONEYGAIN_PASSWORD' -device hg-instance"
