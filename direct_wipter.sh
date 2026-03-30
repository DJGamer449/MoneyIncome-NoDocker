#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/expressvpn_netns_lib.sh"
require_root
EMAIL="${1:-}"; PASS="${2:-}"
[[ -n "$EMAIL" ]] || read -rp "Enter Wipter email: " EMAIL
[[ -n "$PASS" ]] || { read -rsp "Enter Wipter password: " PASS; echo; }
prompt_vpn_inputs
mkdir -p /tmp/wipter_runtime
for ((i=1;i<=INSTANCE_COUNT;i++)); do
  ns="wipterns${i}"; idx=$((150+i))
  setup_netns "$ns" "$idx"; prepare_expressvpn_instance "$ns"
  run_instance "$ns" "${REGIONS_SELECTED[$((i-1))]}" "cd '$BASE_DIR/app/wipter' && HOME='/tmp/wipter_runtime/${ns}' ./wipter.sh '$EMAIL' '$PASS'" "/tmp/wipter_runtime/${ns}.log"
  echo "Started Wipter instance $i in $ns (${REGIONS_SELECTED[$((i-1))]})"
done
wait
