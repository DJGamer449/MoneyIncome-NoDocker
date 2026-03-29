#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
mkdir -p "$WORKDIR"
require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; [[ -x ./app/honeygain_file/honeygain ]] || { echo "honeygain binary missing"; exit 1; }; }
main(){
 require_root; install_expressvpn_files
 local code instances; ask_expressvpn_inputs code instances
 IFS=$'\n' read -r -d '' -a ACCOUNTS < <(printf '%s\0' "${HONEYGAIN_ACCOUNTS:-}") || true
 (( ${#ACCOUNTS[@]} > 0 )) || { echo "Set HONEYGAIN_ACCOUNTS as newline-separated email|password entries"; exit 1; }
 for ((i=1;i<=instances;i++)); do
   ns="${BASE_NS}${i}"; region="$(region_for_idx "$i")"; acct="${ACCOUNTS[$(((i-1)%${#ACCOUNTS[@]}))]}"; email="${acct%%|*}"; pass="${acct#*|}"
   setup_ns "$ns" "$i" "$VETH_PREFIX"
   start_expressvpn_in_ns "$ns" "$code" "$region" "$i" "$WORKDIR/expressvpn_${i}.log"
   ip netns exec "$ns" bash -lc "nohup ./app/honeygain_file/honeygain -tou-accept -email '$email' -pass '$pass' -device 'hg-$i' >'$WORKDIR/app_${i}.log' 2>&1 &"
   echo "[$i] started Honeygain in $ns region=$region account=$email"
 done
 wait
}
main "$@"
