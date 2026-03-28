#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_CMD=( ./app/provider provide )
BASE_NS="${BASE_NS:-urns}"
VETH_PREFIX="${VETH_PREFIX:-ur}"
WORKDIR="${WORKDIR:-/tmp/urnetwork_expressvpn}"
EXPRESSVPNCTL="${EXPRESSVPNCTL:-$SCRIPT_DIR/app/expressvpn/bin/expressvpnctl}"
NS_DNS_LIST="${NS_DNS_LIST:-1.1.1.1 8.8.8.8}"
mkdir -p "$WORKDIR"
REGIONS=(usa-san-francisco usa-new-jersey-2 usa-lincoln-park usa-houston usa-tampa-1 usa-new-jersey-3 usa-brooklyn usa-denver usa-dallas usa-atlanta usa-seattle usa-miami-2 usa-salt-lake-city usa-santa-monica usa-washington-dc usa-new-jersey-1)

require_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; [[ -x "$EXPRESSVPNCTL" ]] || { echo "expressvpnctl not found at $EXPRESSVPNCTL"; exit 1; }; }
prompt_inputs(){ [[ -n "${EXPRESSVPN_KEY:-}" ]] || { read -rsp "Enter ExpressVPN activation key/token: " EXPRESSVPN_KEY; echo; }; [[ -n "${INSTANCE_COUNT:-}" ]] || read -rp "How many URNetwork instances to run? " INSTANCE_COUNT; [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || exit 1; ((INSTANCE_COUNT>0)) || exit 1; }
setup_nat_once(){ sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE; }
create_ns(){ local idx="$1" ns="${BASE_NS}${idx}" h="${VETH_PREFIX}${idx}h" n="${VETH_PREFIX}${idx}n" b=$(( (idx-1)/254+1 )) c=$(( (idx-1)%254+1 )); ip netns add "$ns" 2>/dev/null||true; ip link show "$h" >/dev/null 2>&1 || ip link add "$h" type veth peer name "$n"; ip link set "$n" netns "$ns"; ip addr add "10.${b}.${c}.1/24" dev "$h" 2>/dev/null||true; ip link set "$h" up; ip netns exec "$ns" ip addr add "10.${b}.${c}.2/24" dev "$n" 2>/dev/null||true; ip netns exec "$ns" ip link set lo up; ip netns exec "$ns" ip link set "$n" up; ip netns exec "$ns" ip route replace default via "10.${b}.${c}.1" dev "$n"; mkdir -p "/etc/netns/$ns"; : > "/etc/netns/$ns/resolv.conf"; for d in $NS_DNS_LIST; do echo "nameserver $d" >> "/etc/netns/$ns/resolv.conf"; done; echo "$ns"; }
start_vpn(){ local ns="$1" region="$2" idx="$3"; ip netns exec "$ns" bash -lc "printf '%s' '$EXPRESSVPN_KEY' > '$WORKDIR/code_${idx}.txt'; '$EXPRESSVPNCTL' login '$WORKDIR/code_${idx}.txt' >/dev/null 2>&1 || true; '$EXPRESSVPNCTL' set networklock false >/dev/null 2>&1 || true; '$EXPRESSVPNCTL' set region '$region' >/dev/null 2>&1 || true; '$EXPRESSVPNCTL' connect '$region'" >"$WORKDIR/expressvpn_${idx}.log" 2>&1 & echo $! > "$WORKDIR/expressvpn_${idx}.pid"; sleep 3; }
start_app(){ local ns="$1" idx="$2" inst="$WORKDIR/inst_${idx}"; mkdir -p "$inst"; [[ -d "/root/.urnetwork" ]] && cp -r "/root/.urnetwork" "$inst/"; ip netns exec "$ns" env -i HOME="$inst" PATH="$PATH" bash -lc "cd '$SCRIPT_DIR'; ${APP_CMD[*]}" >"$WORKDIR/app_${idx}.log" 2>&1 & echo $! > "$WORKDIR/app_${idx}.pid"; }
cleanup(){ for f in "$WORKDIR"/*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null || true; done; for ns in $(ip netns list|awk '{print $1}'|grep -E "^${BASE_NS}[0-9]+$"||true); do local i="${ns#$BASE_NS}"; ip link del "${VETH_PREFIX}${i}h" 2>/dev/null||true; ip netns del "$ns" 2>/dev/null||true; rm -rf "/etc/netns/$ns" 2>/dev/null||true; done; }
trap cleanup EXIT
main(){ require_root; prompt_inputs; setup_nat_once; for ((i=1;i<=INSTANCE_COUNT;i++)); do region="${REGIONS[$(( (i-1)%${#REGIONS[@]} ))]}"; ns="$(create_ns "$i")"; echo "[$i] Using region: $region (ns=$ns)"; start_vpn "$ns" "$region" "$i"; start_app "$ns" "$i"; done; wait; }
main "$@"
