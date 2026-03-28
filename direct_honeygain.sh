#!/usr/bin/env bash
set -euo pipefail

INSTANCE_COUNT="${1:-1}"
BASE_NS="${BASE_NS:-honeyns}"
VETH_PREFIX="${VETH_PREFIX:-honey}"
WORKDIR="${WORKDIR:-/tmp/honeygain_multi}"
SERVER="${SERVER:-smart}"
PROTOCOL="${PROTOCOL:-lightwayudp}"
HONEYGAIN_DIR="${HONEYGAIN_DIR:-./app/honeygain_file}"
HONEYGAIN_BIN="${HONEYGAIN_BIN:-$HONEYGAIN_DIR/honeygain}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app/expressvpn_runner_lib.sh"
CTL="$(xvpn_resolve_ctl)"

mkdir -p "$WORKDIR"

read_accounts() {
  if [[ -n "${HONEYGAIN_ACCOUNTS:-}" ]]; then
    mapfile -t ACCOUNTS < <(printf '%s\n' "$HONEYGAIN_ACCOUNTS" | sed '/^\s*$/d')
  elif [[ -n "${HONEYGAIN_EMAIL:-}" && -n "${HONEYGAIN_PASSWORD:-}" ]]; then
    ACCOUNTS=("${HONEYGAIN_EMAIL}|${HONEYGAIN_PASSWORD}")
  else
    echo "Set HONEYGAIN_ACCOUNTS (email|password per line) or HONEYGAIN_EMAIL/HONEYGAIN_PASSWORD"
    exit 1
  fi
}

start_instance() {
  local idx="$1"
  local account="${ACCOUNTS[$(( (idx-1) % ${#ACCOUNTS[@]} ))]}"
  local email="${account%%|*}"
  local password="${account#*|}"
  local ns inst_dir
  ns="$(xvpn_create_ns "$idx" "$BASE_NS" "$VETH_PREFIX")"
  inst_dir="$WORKDIR/inst_${idx}"
  mkdir -p "$inst_dir"

  ip netns exec "$ns" bash -lc "cd '$SCRIPT_DIR'; export HOME='$inst_dir'; '$HONEYGAIN_BIN' -tou-accept -email '$email' -pass '$password' -device honey-$idx" >"$WORKDIR/app_${idx}.log" 2>&1 &
  echo $! >"$WORKDIR/app_${idx}.pid"
}

cleanup() {
  for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done
  xvpn_cleanup_ns "$BASE_NS" "$VETH_PREFIX"
}

main() {
  xvpn_require_root
  [[ -x "$SCRIPT_DIR/$HONEYGAIN_BIN" || -x "$HONEYGAIN_BIN" ]] || { echo "Honeygain binary not found"; exit 1; }
  read_accounts
  xvpn_setup_nat_once
  xvpn_activate_and_connect "$CTL" "$SERVER" "$PROTOCOL"

  for ((i=1; i<=INSTANCE_COUNT; i++)); do
    start_instance "$i"
  done
  wait
}

trap cleanup EXIT
main "$@"
