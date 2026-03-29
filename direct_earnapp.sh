#!/usr/bin/env bash
set -euo pipefail

BASE_NS="${BASE_NS:-earnns}"
VETH_PREFIX="${VETH_PREFIX:-earn}"
WORKDIR="${WORKDIR:-/tmp/earnapp_multi}"
mkdir -p "$WORKDIR"
source "$(cd "$(dirname "$0")" && pwd)/expressvpn_common.sh"

require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; command -v earnapp >/dev/null 2>&1 || { echo "earnapp not found"; exit 1; }; }
setup_nat_once(){ sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE; }
calc_octets(){ local i="$1"; echo $(( (i-1)/254+1 )) $(( (i-1)%254+1 )); }
create_ns_with_veth(){ local idx="$1" ns="${BASE_NS}${idx}" vh="${VETH_PREFIX}${idx}h" vn="${VETH_PREFIX}${idx}n" b c; read -r b c <<<"$(calc_octets "$idx")"; ip netns add "$ns" 2>/dev/null || true; ip link show "$vh" >/dev/null 2>&1 || ip link add "$vh" type veth peer name "$vn"; ip link set "$vn" netns "$ns"; ip addr add "10.${b}.${c}.1/24" dev "$vh" 2>/dev/null || true; ip link set "$vh" up; ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$vn" 2>/dev/null || true; ip netns exec "$ns" ip link set lo up; ip netns exec "$ns" ip link set "$vn" up; ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$vn"; mkdir -p "/etc/netns/$ns"; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"; echo "$ns"; }

start_instance(){ local idx="$1" ns="$2" region="$3" inst_dir="$WORKDIR/inst_${idx}" etc_dir="$inst_dir/etc" uuid_file="$inst_dir/uuid.txt"; mkdir -p "$etc_dir"; [[ -f "$uuid_file" ]] || printf "sdk-node-%s" "$(uuidgen | tr -d '-' | cut -c1-32)" > "$uuid_file"; local uuid="$(cat "$uuid_file")"; printf "%s" "$uuid" > "$etc_dir/uuid"; touch "$etc_dir/status"; chmod a+rw "$etc_dir" "$etc_dir/status" "$etc_dir/uuid"; start_expressvpn_in_ns "$ns" "$idx" "$region" "$WORKDIR"; ip netns exec "$ns" unshare -m bash -lc "mount --make-rprivate / 2>/dev/null || true; mkdir -p /etc/earnapp; mount --bind '$etc_dir' /etc/earnapp; /usr/bin/earnapp start & sleep 5; exec /usr/bin/earnapp run" >"$WORKDIR/app_${idx}.log" 2>&1 & echo $! >"$WORKDIR/app_${idx}.pid"; echo "[$idx] EarnApp ref: https://earnapp.com/r/$uuid"; }
cleanup(){ for f in "$WORKDIR"/app_*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done; for i in $(seq 1 "${INSTANCE_COUNT:-0}"); do ip netns del "${BASE_NS}${i}" 2>/dev/null || true; ip link del "${VETH_PREFIX}${i}h" 2>/dev/null || true; rm -rf "/etc/netns/${BASE_NS}${i}" 2>/dev/null || true; done; }
trap cleanup EXIT

main(){ require_root; ensure_expressvpn_binaries; setup_nat_once; prompt_vpn_settings; for i in $(seq 1 "$INSTANCE_COUNT"); do ns="$(create_ns_with_veth "$i")"; start_instance "$i" "$ns" "${SELECTED_REGIONS[$((i-1))]}"; done; wait; }
main "$@"
