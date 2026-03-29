#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/lib/expressvpn_netns.sh"

INSTANCES="${INSTANCES:-1}"
ACTIVATION_KEY="${EXPRESSVPN_ACTIVATION_KEY:-}"
TRAFF_TOKEN="${TRAFF_TOKEN:-}"
[[ -n "$TRAFF_TOKEN" ]] || { read -rp "Enter Traff token: " TRAFF_TOKEN; }
[[ -n "$ACTIVATION_KEY" ]] || { read -rsp "Enter ExpressVPN activation key: " ACTIVATION_KEY; echo; }

run_isolated_expressvpn_app "traff" "$INSTANCES" "$ACTIVATION_KEY" "./app/cli start accept --token '$TRAFF_TOKEN'"
