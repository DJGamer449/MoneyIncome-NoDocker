#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/expressvpn_netns_lib.sh"
require_root
EMAIL="${1:-}"; PASS="${2:-}"
[[ -n "$EMAIL" ]] || read -rp "Enter Honeygain email: " EMAIL
[[ -n "$PASS" ]] || { read -rsp "Enter Honeygain password: " PASS; echo; }
prompt_vpn_inputs
mkdir -p /tmp/honeygain_runtime
for ((i=1;i<=INSTANCE_COUNT;i++)); do
  ns="honeyns${i}"; idx=$((180+i))
  setup_netns "$ns" "$idx"; prepare_expressvpn_instance "$ns"
  run_instance "$ns" "${REGIONS_SELECTED[$((i-1))]}" "cd '$BASE_DIR' && HOME='/tmp/honeygain_runtime/${ns}' LD_LIBRARY_PATH='$BASE_DIR/app/honeygain_file':\$LD_LIBRARY_PATH '$BASE_DIR/app/honeygain_file/honeygain' -tou-accept -email '$EMAIL' -pass '$PASS' -device 'hg-${ns}'" "/tmp/honeygain_runtime/${ns}.log"
  echo "Started Honeygain instance $i in $ns (${REGIONS_SELECTED[$((i-1))]})"
done
wait
