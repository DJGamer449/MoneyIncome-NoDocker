#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/lib/expressvpn_netns.sh"

INSTANCES="${INSTANCES:-1}"
ACTAR_KEY="${CASTAR_KEY:-}"
ACTIVATION_KEY="${EXPRESSVPN_ACTIVATION_KEY:-}"
[[ -n "$ACTAR_KEY" ]] || { read -rp "Enter Castar key: " ACTAR_KEY; }
[[ -n "$ACTIVATION_KEY" ]] || { read -rsp "Enter ExpressVPN activation key: " ACTIVATION_KEY; echo; }

run_isolated_expressvpn_app "castar" "$INSTANCES" "$ACTIVATION_KEY" "./app/CastarSDK -key='$ACTAR_KEY'"
