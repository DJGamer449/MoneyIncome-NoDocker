#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/expressvpn_netns_lib.sh"
require_root
KEY="${1:-}"; [[ -n "$KEY" ]] || { read -rp "Enter Castar key: " KEY; }
prompt_vpn_inputs
mkdir -p /tmp/castar_runtime
for ((i=1;i<=INSTANCE_COUNT;i++)); do
  ns="castarns${i}"; idx=$((60+i))
  setup_netns "$ns" "$idx"; prepare_expressvpn_instance "$ns"
  run_instance "$ns" "${REGIONS_SELECTED[$((i-1))]}" "cd '$BASE_DIR' && HOME='/tmp/castar_runtime/${ns}' ./app/CastarSDK -key='$KEY'" "/tmp/castar_runtime/${ns}.log"
  echo "Started Castar instance $i in $ns (${REGIONS_SELECTED[$((i-1))]})"
done
wait
