#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/expressvpn_netns_lib.sh"
require_root
prompt_vpn_inputs
mkdir -p /tmp/earnapp_runtime
for ((i=1;i<=INSTANCE_COUNT;i++)); do
  ns="earnns${i}"; idx=$((120+i))
  setup_netns "$ns" "$idx"; prepare_expressvpn_instance "$ns"
  run_instance "$ns" "${REGIONS_SELECTED[$((i-1))]}" "HOME='/tmp/earnapp_runtime/${ns}' /usr/bin/earnapp run" "/tmp/earnapp_runtime/${ns}.log"
  echo "Started EarnApp instance $i in $ns (${REGIONS_SELECTED[$((i-1))]})"
done
wait
