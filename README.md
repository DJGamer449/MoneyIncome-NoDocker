# MoneyIncome NoDocker

![Logo](logo.png)

A unified multi-service Linux network namespace manager for:

-   EarnApp
-   TraffMonetizer
-   PacketStream
-   UrNetwork
-   CastarSDK
-   ExpressVPN (via `expressvpnctl` in `./app/expressvpn/bin`)
-   Honeygain
-   Mysterium Node

Run multiple services simultaneously using isolated Linux network
namespaces with proxy routing.

------------------------------------------------------------------------

## ✨ Features

-   Run **EarnApp, TraffMonetizer, PacketStream, UrNetwork, CastarSDK, Honeygain** at the same time
-   Run **Mysterium Node** instances with isolated per-proxy namespaces
-   Each service runs in its own isolated netns
-   Automatic namespace routing with ExpressVPN
-   Mysterium node connect UI is auto-forwarded from namespace-local `127.0.0.1:4449` to host `127.0.0.1:4450`, `4451`, `4452`, ...
-   Persistent Mysterium data directories are auto-created under `myst/myst-1`, `myst/myst-2`, ...
-   Each Mysterium instance now gets its own HOME/XDG/script directories so identities stay isolated across simultaneous logins
-   Mysterium launch now uses a private mount namespace per instance and bind-mounts isolated app/config/cache paths to prevent cross-instance session/keyring bleed
-   Mysterium runner now probes UDP after tunnel setup and automatically falls back to direct UDP inside the namespace if the SOCKS proxy cannot relay UDP
-   No IP collision (separate namespace prefixes)
-   Live output (no hidden logging)
-   Clean Ctrl+C shutdown
-   Persistent EarnApp UUID handling
-   Works on Ubuntu 22.04 / 24.04

------------------------------------------------------------------------

## 📦 Requirements

-   Ubuntu 22.04 / 24.04
-   Root access
-   iproute2
-   iptables
-   curl
-   uuidgen
-   earnapp installed in /usr/bin/earnapp
-   cli binary for Traff
-   psclient binary for PacketStream
-   Honeygain binary + libs in `app/honeygain_file`

------------------------------------------------------------------------

## 📂 Project Structure

mâin.sh\
direct_earnapp.sh\
direct_traff.sh\
direct_mysterium.sh\
install_mysterium_node.sh\
direct_expressvpn_netns.sh\
proxies.txt

------------------------------------------------------------------------

## 🔧 Proxy Format

Create `proxies.txt`:

protocol://user:pass@ip:port

Example:

http://user:pass@1.2.3.4:8080\
socks5://user:pass@5.6.7.8:1080

------------------------------------------------------------------------

## Installation

Make scripts executable:

chmod +x \*.sh

Run manager:

sudo ./main.sh

Select option:

- `6` to run the ExpressVPN netns network launcher for apps
- `I` to install Mysterium Node
- `M` to run Mysterium Node instances through the proxies in `proxies.txt`

------------------------------------------------------------------------

## Usage

sudo ./main.sh

<img width="390" height="324" alt="image" src="https://github.com/user-attachments/assets/5591b69d-e06d-4577-a35f-c5bdb6be5a79" />


------------------------------------------------------------------------

## How It Works

Each service:

-   Gets its own Linux network namespace
-   Gets its own veth pair
-   Gets its own TUN device
-   Routes traffic through ExpressVPN
-   Uses independent IP ranges

Namespace prefixes:

  Service        Namespace Prefix
  -------------- ------------------
  EarnApp        earnns
  Traff          traffns
  PacketStream   psns

------------------------------------------------------------------------

## Stop Everything

Press Ctrl + C

The script will:

-   Kill all running service processes
-   Remove network namespaces
-   Clean up veth interfaces
-   Exit safely

------------------------------------------------------------------------
## Proof of Concept
<img width="791" height="622" alt="image" src="https://github.com/user-attachments/assets/8af58716-efa1-496b-8b6e-c5c8ce26e3e6" />
<img width="685" height="346" alt="image" src="https://github.com/user-attachments/assets/46d0e27c-510b-47c1-b902-a473055d5a52" />

------------------------------------------------------------------------

## ⚠ Disclaimer

This project is for educational and experimental purposes only.

You are responsible for complying with: - Service Terms of Use - Local
laws - Proxy provider policies

------------------------------------------------------------------------

## 👤 Author

- MelanTrance
- JessAle (UrNetwork Variant)

------------------------------------------------------------------------

## ⭐ Contribute

Pull requests and improvements are welcome. , Make Sure to Give Us a Stars if you found this useful
