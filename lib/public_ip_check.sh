#!/usr/bin/env bash
set -euo pipefail

public_ip_from_ns() {
  local ns="$1"
  ip netns exec "$ns" curl -4fsS --max-time 20 https://api.ipify.org || \
  ip netns exec "$ns" curl -4fsS --max-time 20 https://ifconfig.me/ip
}

is_unique_public_ip() {
  local candidate="$1"
  shift || true
  local ip
  for ip in "$@"; do
    [[ "$ip" == "$candidate" ]] && return 1
  done
  return 0
}
