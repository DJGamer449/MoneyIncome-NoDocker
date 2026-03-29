#!/usr/bin/env bash
set -euo pipefail

APP_CMD=( ./app/CastarSDK -key="key" )
BASE_NS="${BASE_NS:-castarns}"
VETH_PREFIX="${VETH_PREFIX:-castar}"
WORKDIR="${WORKDIR:-/tmp/castar_multi}"
mkdir -p "$WORKDIR"

source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"

require_root() { [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; }
setup_nat_once() { sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE; }
calc_octets(){ local i="$1"; echo $(( (i-1)/254+1 )) $(( (i-1)%254+1 )); }
create_ns_with_veth(){ local idx="$1" ns="${BASE_NS}${idx}" vh="${VETH_PREFIX}${idx}h" vn="${VETH_PREFIX}${idx}n" b c; read -r b c <<<"$(calc_octets "$idx")"; ip netns add "$ns" 2>/dev/null || true; ip link show "$vh" >/dev/null 2>&1 || ip link add "$vh" type veth peer name "$vn"; ip link set "$vn" netns "$ns"; ip addr add "10.${b}.${c}.1/24" dev "$vh" 2>/dev/null || true; ip link set "$vh" up; ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$vn" 2>/dev/null || true; ip netns exec "$ns" ip link set lo up; ip netns exec "$ns" ip link set "$vn" up; ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$vn"; mkdir -p "/etc/netns/$ns"; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"; echo "$ns"; }

start_instance(){ local idx="$1" ns="$2" region="$3"; start_expressvpn_in_ns "$ns" "$idx" "$region" "$WORKDIR"; ip netns exec "$ns" bash -lc "cd '$(pwd)'; ${APP_CMD[*]}" >"$WORKDIR/app_${idx}.log" 2>&1 & echo $! >"$WORKDIR/app_${idx}.pid"; }
cleanup(){ for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done; for i in $(seq 1 "${INSTANCE_COUNT:-0}"); do ip netns del "${BASE_NS}${i}" 2>/dev/null || true; ip link del "${VETH_PREFIX}${i}h" 2>/dev/null || true; rm -rf "/etc/netns/${BASE_NS}${i}" 2>/dev/null || true; done; }
trap cleanup EXIT

main(){ require_root; ensure_expressvpn_binaries; setup_nat_once; prompt_vpn_settings; for i in $(seq 1 "$INSTANCE_COUNT"); do ns="$(create_ns_with_veth "$i")"; start_instance "$i" "$ns" "${SELECTED_REGIONS[$((i-1))]}"; done; echo "Started $INSTANCE_COUNT castar instance(s) via ExpressVPN"; wait; }
main "$@"
