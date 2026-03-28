#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[expressvpn-start] $*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="${SCRIPT_DIR}/expressvpn/bin/expressvpnctl"

if [[ ! -x "${CTL}" ]]; then
  log "expressvpnctl not found or not executable at ${CTL}"
  exit 1
fi

restart_service() {
  local service_name=""
  if [[ -f /etc/init.d/expressvpn-service ]]; then
    service_name="expressvpn-service"
  elif [[ -f /etc/init.d/expressvpn ]]; then
    service_name="expressvpn"
  else
    log "Could not find expressvpn service script"
    exit 1
  fi

  service "${service_name}" stop >/dev/null 2>&1 || true
  service "${service_name}" start >/dev/null
}

wait_for_daemon() {
  local tries="${1:-30}"
  local i
  for i in $(seq 1 "${tries}"); do
    if "${CTL}" status >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_connected() {
  local tries="${1:-60}"
  local i
  for i in $(seq 1 "${tries}"); do
    if [[ "$("${CTL}" get connectionstate 2>/dev/null || true)" == "Connected" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

activate_account() {
  if [[ -z "${CODE:-}" ]]; then
    read -r -s -p "Enter ExpressVPN activation key: " CODE
    echo
  fi

  if [[ -z "${CODE:-}" ]]; then
    log "Activation key is required"
    exit 1
  fi

  local code_file
  code_file="$(mktemp)"
  printf '%s' "${CODE}" >"${code_file}"

  if ! out=$("${CTL}" --timeout 60 login "${code_file}" 2>&1); then
    rm -f "${code_file}"
    if grep -qi "Already logged into account" <<<"${out}"; then
      log "Already logged in"
      return 0
    fi
    log "Login failed: ${out}"
    exit 1
  fi

  rm -f "${code_file}"
}

connect_vpn() {
  local server="${SERVER:-smart}"
  local protocol="${PROTOCOL:-lightwayudp}"

  "${CTL}" set protocol "${protocol}" >/dev/null 2>&1 || true
  "${CTL}" disconnect >/dev/null 2>&1 || true
  "${CTL}" connect "${server}"

  if ! wait_for_connected; then
    log "Timed out waiting for VPN to connect to ${server}"
    exit 1
  fi

  log "Connected to ${server}"
}

main() {
  restart_service

  if ! wait_for_daemon; then
    log "ExpressVPN daemon did not become ready"
    exit 1
  fi

  activate_account
  connect_vpn

  if [[ $# -gt 0 ]]; then
    exec "$@"
  fi

  tail -f /dev/null
}

main "$@"
