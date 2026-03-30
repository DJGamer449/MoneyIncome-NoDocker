#!/usr/bin/env bash
set -euo pipefail

log() { echo "[expressvpn-start] $*"; }

require_bin() {
  command -v expressvpnctl >/dev/null 2>&1 || { log "expressvpnctl is required"; exit 1; }
  command -v service >/dev/null 2>&1 || { log "service is required"; exit 1; }
}

restore_resolver() {
  local resolv="/etc/resolv.conf"
  if [[ -f "$resolv" ]]; then
    cp "$resolv" "${resolv}.bak"
    umount "$resolv" >/dev/null 2>&1 || true
    cp "${resolv}.bak" "$resolv"
    rm -f "${resolv}.bak"
  fi
}

ensure_service_script() {
  if [[ -f /etc/init.d/expressvpn-service ]]; then
    SERVICE_SCRIPT="expressvpn-service"
    return
  fi
  if [[ -f /etc/init.d/expressvpn ]]; then
    SERVICE_SCRIPT="expressvpn"
    return
  fi
  log "Missing /etc/init.d/expressvpn-service or /etc/init.d/expressvpn"
  exit 1
}

restart_service() {
  service "$SERVICE_SCRIPT" stop >/dev/null 2>&1 || true
  service "$SERVICE_SCRIPT" start >/dev/null 2>&1 || { log "Failed to start $SERVICE_SCRIPT"; exit 1; }
}

wait_for_daemon() {
  local i
  for i in $(seq 1 20); do
    expressvpnctl status >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

activate_if_needed() {
  [[ -n "${CODE:-}" ]] || { log "CODE=<activation-key> is required"; exit 1; }
  local code_file
  code_file=$(mktemp)
  printf '%s' "$CODE" > "$code_file"
  expressvpnctl --timeout 60 login "$code_file" >/tmp/expressvpn/login.log 2>&1 || true
  rm -f "$code_file"
}

connect_region() {
  local region="${SERVER:-smart}"
  expressvpnctl disconnect >/dev/null 2>&1 || true
  expressvpnctl connect "$region" >/tmp/expressvpn/connect.log 2>&1 || { log "Connect failed: $region"; exit 1; }
}

wait_connected() {
  local i
  for i in $(seq 1 30); do
    [[ "$(expressvpnctl get connectionstate 2>/dev/null || true)" == "Connected" ]] && return 0
    sleep 1
  done
  return 1
}

prepare_runtime_files() {
  mkdir -p /tmp/expressvpn /expressvpn/www
  touch /tmp/metrics-socat.log /tmp/metrics-httpd.log /tmp/expressvpn/reconnect-failure.flag
  [[ -f /expressvpn/uname.sh ]] && bash /expressvpn/uname.sh || true
  [[ -f /expressvpn/metrics.cgi ]] && cp /expressvpn/metrics.cgi /expressvpn/www/metrics.cgi || true
  [[ -x /expressvpn/metrics-server.sh ]] || true
  [[ -x /expressvpn/control-server.sh ]] || true
}

main() {
  require_bin
  restore_resolver
  ensure_service_script
  prepare_runtime_files
  restart_service
  wait_for_daemon || { log "ExpressVPN daemon not ready"; exit 1; }
  activate_if_needed
  connect_region
  wait_connected || { log "ExpressVPN connection timeout"; exit 1; }
  log "Connected to ${SERVER:-smart}"
}

main "$@"
