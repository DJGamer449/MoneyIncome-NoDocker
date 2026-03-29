#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/lib/expressvpn_netns.sh"

INSTANCES="${INSTANCES:-1}"
ACTIVATION_KEY="${EXPRESSVPN_ACTIVATION_KEY:-}"
WIPTER_EMAIL="${WIPTER_EMAIL:-}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-}"
[[ -n "$WIPTER_EMAIL" ]] || read -rp "Enter Wipter email: " WIPTER_EMAIL
[[ -n "$WIPTER_PASSWORD" ]] || { read -rsp "Enter Wipter password: " WIPTER_PASSWORD; echo; }
[[ -n "$ACTIVATION_KEY" ]] || { read -rsp "Enter ExpressVPN activation key: " ACTIVATION_KEY; echo; }

run_isolated_expressvpn_app "wipter" "$INSTANCES" "$ACTIVATION_KEY" "cd ./app/wipter && WIPTER_EMAIL='$WIPTER_EMAIL' WIPTER_PASSWORD='$WIPTER_PASSWORD' ./wipter.sh"
