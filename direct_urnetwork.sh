#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/lib/expressvpn_netns.sh"

INSTANCES="${INSTANCES:-1}"
ACTIVATION_KEY="${EXPRESSVPN_ACTIVATION_KEY:-}"
[[ -n "$ACTIVATION_KEY" ]] || { read -rsp "Enter ExpressVPN activation key: " ACTIVATION_KEY; echo; }

run_isolated_expressvpn_app "urnetwork" "$INSTANCES" "$ACTIVATION_KEY" "./app/provider provide"
