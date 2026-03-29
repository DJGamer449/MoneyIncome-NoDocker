#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPRESSVPN_ROOT="${EXPRESSVPN_ROOT:-$SCRIPT_DIR}"
EXPRESSVPN_BIN_DIR="${EXPRESSVPN_BIN_DIR:-$EXPRESSVPN_ROOT/bin}"
export PATH="$EXPRESSVPN_BIN_DIR:$PATH"

log() {
    echo "[start] $*"
}

xvpnctl() {
    expressvpnctl "$@"
}

has_ctl() {
    command -v expressvpnctl >/dev/null 2>&1
}

restore_resolver() {
    local resolv="/etc/resolv.conf"

    if [[ -f "$resolv" ]]; then
        cp "$resolv" "${resolv}.bak"
        umount "$resolv" &>/dev/null || true
        cp "${resolv}.bak" "$resolv"
        rm -f "${resolv}.bak"
    fi
}

restart_service() {
    local service_name=""
    if [[ -f /etc/init.d/expressvpn-service ]]; then
        service_name="expressvpn-service"
    elif [[ -f /etc/init.d/expressvpn ]]; then
        service_name="expressvpn"
    fi

    if [[ -z "$service_name" ]]; then
        log "Unable to locate expressvpn init script"
        exit 1
    fi

    service "$service_name" stop >/dev/null 2>&1 || true
    if service_output=$(service "$service_name" start 2>&1); then
        log "$service_output"
    else
        log "$service_output"
        log "Service ${service_name} start failed!"
        exit 1
    fi
}

wait_for_condition() {
    local attempts="$1"
    local delay="$2"
    local check_fn="$3"
    local attempt

    for attempt in $(seq 1 "$attempts"); do
        if "$check_fn"; then
            return 0
        fi
        sleep "$delay"
    done

    return 1
}

check_daemon() {
    xvpnctl status >/dev/null 2>&1
}

wait_for_daemon() {
    wait_for_condition 10 2 check_daemon
}

activate_account() {
    local output
    if [[ -z ${CODE:-} ]]; then
        log "Activation code is required (CODE)."
        exit 1
    fi
    if ! wait_for_daemon; then
        log "ExpressVPN daemon not responding; activation aborted."
        exit 1
    fi
    local code_file
    code_file=$(mktemp)
    printf '%s' "${CODE}" >"${code_file}"
    if ! output=$(xvpnctl --timeout 60 login "${code_file}" 2>&1); then
        rm -f "${code_file}"
        if grep -qi "Already logged into account" <<<"$output"; then
            log "$output"
            log "Already logged in; skipping activation."
            return
        fi
        log "$output"
        log "Activation command failed!"
        exit 1
    fi
    rm -f "${code_file}"
    if ! xvpnctl background enable >/dev/null 2>&1; then
        log "Unable to enable expressvpnctl background mode."
    fi
}

set_protocol() {
    local value="$1"
    if [[ -z "$value" ]]; then
        value="auto"
    fi
    value="${value,,}"
    case "$value" in
        auto|lightwayudp|lightwaytcp|openvpnudp|openvpntcp|wireguard) ;;
        *)
            log "Unsupported PROTOCOL value: ${value}"
            exit 1
            ;;
    esac
    if ! xvpnctl set protocol "$value" 2>/dev/null; then
        log "Unable to set protocol to ${value}"
        exit 1
    fi
}

wait_for_smart_location() {
    local attempts=15
    local delay=2
    local attempt
    local initial
    local current

    initial=$(xvpnctl get smart 2>/dev/null || true)
    [[ -z "$initial" ]] && return 0

    for attempt in $(seq 1 "$attempts"); do
        sleep "$delay"
        current=$(xvpnctl get smart 2>/dev/null || true)
        if [[ -n "$current" && "$current" != "$initial" ]]; then
            log "Smart location updated from ${initial} to ${current}"
            return 0
        fi
    done

    log "Smart location stayed at ${initial}; connecting anyway"
}

check_connected() {
    [[ "$(xvpnctl get connectionstate 2>/dev/null || true)" == "Connected" ]]
}

wait_for_connection() {
    if ! wait_for_condition 15 2 check_connected; then
        log "Timed out waiting for VPN connection."
    fi
}

apply_lan_routes() {
    if [[ ${ALLOW_LAN:-true} != "true" ]]; then
        return
    fi
    if [[ -z ${LAN_CIDR:-} ]]; then
        return
    fi
    local gateway
    gateway=$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')
    if [[ -z "$gateway" ]]; then
        log "Unable to determine default gateway for LAN routes."
        return
    fi
    local default_iface
    default_iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')
    if [[ -z "$default_iface" ]]; then
        log "Unable to determine default network interface for LAN routes."
        return
    fi
    local cidr_list="${LAN_CIDR//,/ }"
    for cidr in $cidr_list; do
        ip route replace "$cidr" via "$gateway" dev "$default_iface"
        log "Added LAN route for ${cidr} via ${gateway} on ${default_iface}"
    done
}

configure_preferences() {
    set_protocol "${PROTOCOL:-lightwayudp}"
    [[ -f "$EXPRESSVPN_ROOT/uname.sh" ]] && bash "$EXPRESSVPN_ROOT/uname.sh" || true

    if ! xvpnctl set allowlan "${ALLOW_LAN:-true}" >/dev/null 2>&1; then
        log "Unable to set allowlan to ${ALLOW_LAN:-true}"
    fi
    if ! xvpnctl set autoconnect false >/dev/null 2>&1; then
        log "Unable to set autoconnect to false"
    fi

    xvpnctl disconnect >/dev/null 2>&1 || true
    if [[ "${SERVER:-smart}" == "smart" ]]; then
        wait_for_smart_location
    fi
    if ! xvpnctl connect "${SERVER:-smart}"; then
        log "Unable to connect to ${SERVER:-smart}"
        exit 1
    fi
    wait_for_connection
    if ! xvpnctl set autoconnect true >/dev/null 2>&1; then
        log "Unable to set autoconnect to true"
    fi
    apply_lan_routes
}

supervise_connection_loop() {
    local interval="${CONNECTION_CHECK_INTERVAL:-30}"
    local target="${SERVER:-smart}"

    log "Entering supervision loop (interval ${interval}s) to keep ${target} connected."
    while true; do
        if ! check_connected || [[ ! -d /sys/class/net/tun0 ]]; then
            log "VPN down (missing tun0 or not connected). Attempting reconnect to ${target}..."
            xvpnctl connect "${target}" >/dev/null 2>&1 || true
            wait_for_connection
        fi
        sleep "${interval}"
    done
}

main() {
    if ! has_ctl; then
        log "expressvpnctl not found. Expected in ${EXPRESSVPN_BIN_DIR}."
        exit 1
    fi

    restore_resolver
    restart_service
    activate_account
    configure_preferences

    if [[ $# -gt 0 ]]; then
        "$@"
        exit $?
    fi

    supervise_connection_loop
}

main "$@"
