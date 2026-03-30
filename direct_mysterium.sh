#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/expressvpn_netns_lib.sh"
require_root
MYST_BIN="${MYST_BIN:-/usr/local/bin/myst}"
[[ -x "$MYST_BIN" ]] || { echo "myst not found at $MYST_BIN"; exit 1; }
prompt_vpn_inputs
mkdir -p /tmp/mysterium_runtime
for ((i=1;i<=INSTANCE_COUNT;i++)); do
  ns="mysterns${i}"; idx=$((210+i))
  setup_netns "$ns" "$idx"; prepare_expressvpn_instance "$ns"
  run_instance "$ns" "${REGIONS_SELECTED[$((i-1))]}" "mkdir -p '/tmp/mysterium_runtime/${ns}'; HOME='/tmp/mysterium_runtime/${ns}' '$MYST_BIN' --tequilapi.address=0.0.0.0 --tequilapi.port=$((4449+i)) --config-dir='/tmp/mysterium_runtime/${ns}/config' --data-dir='/tmp/mysterium_runtime/${ns}/data' --runtime-dir='/tmp/mysterium_runtime/${ns}/run'" "/tmp/mysterium_runtime/${ns}.log"
  echo "Started Mysterium instance $i in $ns (${REGIONS_SELECTED[$((i-1))]})"
done
wait
