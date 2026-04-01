#!/usr/bin/env bash
set -euo pipefail

EXPRESSVPN_DIR="${EXPRESSVPN_DIR:-/opt/expressvpn}"
DAEMON_BIN="${DAEMON_BIN:-$EXPRESSVPN_DIR/bin/expressvpn-daemon}"
CTL_BIN="${CTL_BIN:-$EXPRESSVPN_DIR/bin/expressvpnctl}"

# Smaller caches/logging reduce per-container memory + disk write pressure.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/xdg-cache}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
export TMPDIR="${TMPDIR:-/tmp}"
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

mkdir -p "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$EXPRESSVPN_DIR/var"
chmod 700 "$XDG_RUNTIME_DIR" || true

if [[ ! -x "$DAEMON_BIN" ]]; then
  echo "[entrypoint] missing daemon binary: $DAEMON_BIN" >&2
  exit 1
fi

# Optional per-container CPU affinity for better density.
if [[ -n "${CPU_AFFINITY:-}" ]]; then
  exec taskset -c "$CPU_AFFINITY" "$DAEMON_BIN"
fi

exec "$DAEMON_BIN"
