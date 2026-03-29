#!/usr/bin/env bash
set -euo pipefail
BASE_NS="${BASE_NS:-wipterns}"; VETH_PREFIX="${VETH_PREFIX:-wipter}"; WORKDIR="${WORKDIR:-/tmp/wipter_multi}"; WIPTER_DIR="${WIPTER_DIR:-./app/wipter}"; mkdir -p "$WORKDIR"
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"
require_root(){ [[ $EUID -eq 0 ]] || exit 1; [[ -n "${WIPTER_EMAIL:-}" && -n "${WIPTER_PASSWORD:-}" ]] || { echo "WIPTER_EMAIL/WIPTER_PASSWORD required"; exit 1; }; }
setup_nat_once(){ sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE; }
calc_octets(){ local i="$1"; echo $(( (i-1)/254+1 )) $(( (i-1)%254+1 )); }
create_ns(){ local i="$1" ns="${BASE_NS}${i}" vh="${VETH_PREFIX}${i}h" vn="${VETH_PREFIX}${i}n" b c; read -r b c <<<"$(calc_octets "$i")"; ip netns add "$ns" 2>/dev/null || true; ip link show "$vh" >/dev/null 2>&1 || ip link add "$vh" type veth peer name "$vn"; ip link set "$vn" netns "$ns"; ip addr add "10.${b}.${c}.1/24" dev "$vh" 2>/dev/null || true; ip link set "$vh" up; ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$vn" 2>/dev/null || true; ip netns exec "$ns" ip link set lo up; ip netns exec "$ns" ip link set "$vn" up; ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$vn"; echo "$ns"; }
cleanup(){ for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done; for i in $(seq 1 "${INSTANCE_COUNT:-0}"); do ip netns del "${BASE_NS}${i}" 2>/dev/null || true; ip link del "${VETH_PREFIX}${i}h" 2>/dev/null || true; done; }
trap cleanup EXIT
main(){ require_root; ensure_expressvpn_binaries; setup_nat_once; prompt_vpn_settings; for i in $(seq 1 "$INSTANCE_COUNT"); do ns="$(create_ns "$i")"; start_expressvpn_in_ns "$ns" "$i" "${SELECTED_REGIONS[$((i-1))]}" "$WORKDIR"; ip netns exec "$ns" env WIPTER_EMAIL="$WIPTER_EMAIL" WIPTER_PASSWORD="$WIPTER_PASSWORD" bash -lc "cd '$WIPTER_DIR'; ./wipter.sh" >"$WORKDIR/app_${i}.log" 2>&1 & echo $! >"$WORKDIR/app_${i}.pid"; done; wait; }
main "$@"
