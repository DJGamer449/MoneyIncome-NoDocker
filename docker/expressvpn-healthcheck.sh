#!/usr/bin/env bash
set -euo pipefail

CTL_BIN="${CTL_BIN:-/opt/expressvpn/bin/expressvpnctl}"

# Fast path: daemon process exists.
pidof expressvpn-daemon >/dev/null 2>&1 && exit 0

# Fallback path: ping CLI with strict timeout.
timeout 3s "$CTL_BIN" status >/dev/null 2>&1
