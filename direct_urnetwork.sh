#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/expressvpn_netns_lib.sh"
require_root
prompt_vpn_inputs
mkdir -p /tmp/urnetwork_runtime
for ((i=1;i<=INSTANCE_COUNT;i++)); do
  ns="urns${i}"; idx=$((90+i))
  setup_netns "$ns" "$idx"; prepare_expressvpn_instance "$ns"
  run_instance "$ns" "${REGIONS_SELECTED[$((i-1))]}" "cd '$BASE_DIR' && HOME='/tmp/urnetwork_runtime/${ns}' ./app/provider provide" "/tmp/urnetwork_runtime/${ns}.log"
  echo "Started UrNetwork instance $i in $ns (${REGIONS_SELECTED[$((i-1))]})"
done
wait
