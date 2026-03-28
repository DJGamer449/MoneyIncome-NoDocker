# MoneyIncome NoDocker

ExpressVPN-first multi-service namespace runner for:

- EarnApp
- TraffMonetizer
- PacketStream
- UrNetwork
- CastarSDK
- Honeygain
- Mysterium Node

## What changed

This repo now uses **ExpressVPN only** for traffic routing.
The old `hev-socks5-tunnel` proxy path was removed from application runners.

## Requirements

- Ubuntu 22.04 / 24.04
- Root access
- `iproute2`, `iptables`
- ExpressVPN CLI available at `./app/expressvpn/bin/expressvpnctl` (or in `PATH`)
- App binaries already present under `./app`

## Usage

```bash
chmod +x *.sh app/expressvpn_runner_lib.sh
sudo ./main.sh
```

When a runner starts, it will ask for `CODE` (ExpressVPN activation key) if not already exported.
You can also set these ahead of time:

```bash
export CODE="your-expressvpn-key"
export SERVER="smart"
export PROTOCOL="lightwayudp"
```

Optional instance controls per app in `main.sh` flow:

- `EARNAPP_INSTANCES`
- `TRAFF_INSTANCES`
- `PS_INSTANCES`
- `UR_INSTANCES`
- `CASTAR_INSTANCES`
- `WIPTER_INSTANCES`
- `HONEY_INSTANCES`
- `MYST_INSTANCES`

## Notes

- Network namespaces and veth pairs are still used for instance isolation.
- VPN connection is done with ExpressVPN; no per-proxy `proxies.txt` workflow is required.
