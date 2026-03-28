#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[expressvpn-instance] $*"
}

wait_for_connected() {
  local timeout="${CONNECT_TIMEOUT:-180}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if [[ "$(expressvpnctl get connectionstate 2>/dev/null || true)" == "Connected" ]]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

main() {
  local code="${CODE:-${EXPRESSVPN_CODE:-}}"
  local server="${SERVER:-smart}"
  local protocol="${PROTOCOL:-lightwayudp}"

  command -v expressvpnctl >/dev/null 2>&1 || {
    log "expressvpnctl not found in namespace"
    exit 1
  }

  if [[ -z "$code" ]]; then
    log "Missing activation code. Set CODE or EXPRESSVPN_CODE"
    exit 1
  fi

  local code_file
  code_file="$(mktemp)"
  printf '%s' "$code" >"$code_file"
  if ! login_output="$(expressvpnctl --timeout 60 login "$code_file" 2>&1)"; then
    if ! grep -qi "Already logged into account" <<<"$login_output"; then
      rm -f "$code_file"
      log "Login failed: $login_output"
      exit 1
    fi
  fi
  rm -f "$code_file"

  expressvpnctl set protocol "$protocol" >/dev/null 2>&1 || true
  expressvpnctl disconnect >/dev/null 2>&1 || true
  expressvpnctl connect "$server"

  if ! wait_for_connected; then
    log "Timed out waiting for connection to $server"
    exit 1
  fi

  log "Connected to $server"

  if [[ -n "${APP_CMD:-}" ]]; then
    exec bash -lc "$APP_CMD"
  fi

  exec sleep infinity
}

main "$@"
