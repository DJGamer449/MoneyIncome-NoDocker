# MoneyIncome NoDocker (ExpressVPN netns)

This branch migrates all app runners from `hev-socks5-tunnel`/`proxies.txt` to **ExpressVPN** with Linux network namespaces and per-instance isolation.

## What changed

- Every app instance runs in its own netns (`<app>ns1`, `<app>ns2`, ...).
- Every instance has isolated runtime under `/tmp/<app>_multi/inst_<n>/expressvpn`.
- Uses full ExpressVPN paths only:
  - `/opt/expressvpn/bin/expressvpnctl`
  - `/opt/expressvpn/bin/expressvpn-daemon`
  - helper scripts from `/opt/expressvpn`
- Asks once for:
  - ExpressVPN activation key
  - number of instances
- Regions are assigned in fixed order and cycle when list is exhausted.
- Each instance verifies public IP from inside its namespace.
- Duplicate public IPs trigger reconnect with next region and retry.
- App launch is blocked if VPN is not connected.
- Network lock is enabled and namespace firewall defaults deny to avoid host fallback leaks.
- Cleanup removes stale namespaces, pids, and `/tmp/<app>_multi` instance data.

## Menu

Run:

```bash
sudo ./main.sh
```

Main options:
- Install ExpressVPN dependencies
- Run selected app through isolated ExpressVPN instances
- Run ALL apps through isolated ExpressVPN instances

Supported app flows:
- EarnApp
- Traff
- PacketStream
- UrNetwork
- Castar
- Honeygain
- Wipter
- Mysterium

## Scripts

- `install_expressvpn.sh`
- `lib/expressvpn_netns.sh`
- `lib/instance_regions.sh`
- `lib/public_ip_check.sh`
- `direct_earnapp.sh`
- `direct_traff.sh`
- `direct_urnetwork.sh`
- `direct_castar.sh`
- `direct_honeygain.sh`
- `direct_wipter.sh`
- `direct_mysterium.sh`

`install_hev-socks5-tunnel.sh` is now a compatibility shim that forwards to ExpressVPN installation.

## Notes

- This is **NO-DOCKER** and uses Linux namespaces directly.
- Run as root.
- ExpressVPN package itself must already provide `/opt/expressvpn/bin/*`.
