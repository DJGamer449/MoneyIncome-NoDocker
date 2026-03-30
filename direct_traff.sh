#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/expressvpn_netns_lib.sh"
require_root
TOKEN="${1:-}"; [[ -n "$TOKEN" ]] || { read -rp "Enter Traff token: " TOKEN; }
prompt_vpn_inputs
mkdir -p /tmp/traff_runtime
for ((i=1;i<=INSTANCE_COUNT;i++)); do
  ns="traffns${i}"; idx=$((30+i))
  setup_netns "$ns" "$idx"
  prepare_expressvpn_instance "$ns"
  run_instance "$ns" "${REGIONS_SELECTED[$((i-1))]}" "cd '$BASE_DIR' && HOME='/tmp/traff_runtime/${ns}' ./app/cli start accept --token '$TOKEN'" "/tmp/traff_runtime/${ns}.log"
  echo "Started Traff instance $i in $ns (${REGIONS_SELECTED[$((i-1))]})"
done
wait
