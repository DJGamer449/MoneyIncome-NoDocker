# MoneyIncome NoDocker

![Logo](logo.png)

A unified multi-service Linux network namespace manager for:

-   EarnApp
-   TraffMonetizer
-   PacketStream
-   UrNetwork
-   tun2socks (xjasonlyu native binary)

Run multiple services simultaneously using isolated Linux network
namespaces with proxy routing.

------------------------------------------------------------------------

## ✨ Features

-   Run **EarnApp, TraffMonetizer, PacketStream** at the same time
-   Each service runs in its own isolated netns
-   Automatic proxy routing via tun2socks
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

------------------------------------------------------------------------

## 📂 Project Structure

mâin.sh\
direct_earnapp.sh\
direct_traff.sh\
install_tun2socks.sh\
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

4)  Install tun2socks

------------------------------------------------------------------------

## Usage

sudo ./main.sh

Menu options:

1)  Run EarnApp\
2)  Run Traff\
3)  Run PacketStream\
4)  Install tun2socks\
5)  Run ALL\
6)  Exit

------------------------------------------------------------------------

## How It Works

Each service:

-   Gets its own Linux network namespace
-   Gets its own veth pair
-   Gets its own TUN device
-   Routes traffic through tun2socks
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

## ⚠ Disclaimer

This project is for educational and experimental purposes only.

You are responsible for complying with: - Service Terms of Use - Local
laws - Proxy provider policies

------------------------------------------------------------------------

## 👤 Author

MelanTrance
JessAle (UrNetwork Variant)

------------------------------------------------------------------------

## ⭐ Contribute

Pull requests and improvements are welcome.
