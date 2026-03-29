#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/lib/expressvpn_netns.sh"

INSTANCES="${INSTANCES:-1}"
ACTIVATION_KEY="${EXPRESSVPN_ACTIVATION_KEY:-}"
HONEYGAIN_EMAIL="${HONEYGAIN_EMAIL:-}"
HONEYGAIN_PASSWORD="${HONEYGAIN_PASSWORD:-}"
[[ -n "$HONEYGAIN_EMAIL" ]] || read -rp "Enter Honeygain email: " HONEYGAIN_EMAIL
[[ -n "$HONEYGAIN_PASSWORD" ]] || { read -rsp "Enter Honeygain password: " HONEYGAIN_PASSWORD; echo; }
[[ -n "$ACTIVATION_KEY" ]] || { read -rsp "Enter ExpressVPN activation key: " ACTIVATION_KEY; echo; }

run_isolated_expressvpn_app "honeygain" "$INSTANCES" "$ACTIVATION_KEY" "./app/honeygain_file/honeygain -tou-accept -email '$HONEYGAIN_EMAIL' -pass '$HONEYGAIN_PASSWORD' -device '{IDX}'"
