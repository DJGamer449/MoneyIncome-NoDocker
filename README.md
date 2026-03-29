# MoneyIncome-NoDocker (ExpressVPN isolated mode)

This project now launches each app instance in an isolated ExpressVPN-backed runtime.

## What changed

- `hev-socks5-tunnel` flow has been replaced by `misioslav/expressvpn` containers.
- Every instance gets its own isolated network namespace (container netns) and unique VPN egress IP.
- The launcher asks for:
  1. ExpressVPN activation key
  2. Number of instances
- Regions are assigned instance-by-instance from `expressvpn_regions.sh`; when the list ends, it loops from the start.
- Each instance writes separate files under:
  - `runtime/expressvpn/<app>/instance-<n>/instance.env`
  - `runtime/expressvpn/<app>/instance-<n>/run.sh`
  - `runtime/expressvpn/<app>/instance-<n>/container.log`

## Install runtime

```bash
bash install_expressvpn.sh
```

## Run

```bash
bash main.sh
```

Then choose the app from the menu.
