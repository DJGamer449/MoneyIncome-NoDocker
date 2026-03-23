#!/usr/bin/env bash
set -euo pipefail

# Based on the upstream installer:
# https://raw.githubusercontent.com/mysteriumnetwork/node/master/install.sh

export DEBIAN_FRONTEND="noninteractive"

SNAPSHOT="${SNAPSHOT:-false}"
NETWORK="${NETWORK:-}"

if [[ "$SNAPSHOT" == "true" ]]; then
  PPA="ppa:mysteriumnetwork/node-dev"
  PPA_URL="http://ppa.launchpad.net/mysteriumnetwork/node-dev/ubuntu"
  PPA_FINGER="ECCB6A56B22C536D"
elif [[ "$NETWORK" == "testnet3" ]]; then
  PPA="ppa:mysteriumnetwork/node-testnet3"
  PPA_URL="http://ppa.launchpad.net/mysteriumnetwork/node-testnet3/ubuntu"
  PPA_FINGER="ECCB6A56B22C536D"
else
  PPA="ppa:mysteriumnetwork/node"
  PPA_URL="http://ppa.launchpad.net/mysteriumnetwork/node/ubuntu"
  PPA_FINGER="ECCB6A56B22C536D"
fi

get_linux_distribution() {
  if [[ -f /etc/os-release ]]; then
    awk -F= '$1=="ID" { print $2; exit }' /etc/os-release | tr -d '"'
  else
    echo "unknown"
  fi
}

get_version_codename() {
  if [[ -f /etc/os-release ]]; then
    awk -F= '$1=="VERSION_CODENAME" { print $2; exit }' /etc/os-release | tr -d '"'
  else
    echo "unknown"
  fi
}

prepare_sources_list() {
  local codename="$1"

  if [[ "$codename" == "buster" ]]; then
    echo "deb http://deb.debian.org/debian ${codename}-backports main" | sudo tee /etc/apt/sources.list.d/backports.list >/dev/null
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 04EE7237B7D453EC
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 648ACFD622F3D138
  else
    echo "deb http://deb.debian.org/debian/ unstable main" | sudo tee /etc/apt/sources.list.d/unstable.list >/dev/null
    printf 'Package: *\nPin: release a=unstable\nPin-Priority: 90\n' | sudo tee /etc/apt/preferences.d/limit-unstable >/dev/null
  fi
}

install_mysterium_node() {
  local distro codename
  distro="$(get_linux_distribution)"
  codename="$(get_version_codename)"

  echo "### Installing Mysterium node for distro=$distro codename=$codename"

  sudo apt update
  sudo apt install -y curl wget jq iproute2 iptables net-tools software-properties-common socat

  case "$distro" in
    ubuntu)
      if [[ "${container:-}" != "docker" ]]; then
        sudo apt install -y "linux-headers-$(uname -r)" || true
      fi
      sudo add-apt-repository -y "$PPA"
      sudo apt update
      sudo apt install -y myst
      ;;
    *)
      if [[ "${container:-}" != "docker" ]]; then
        prepare_sources_list "$codename"
        sudo apt update
        sudo apt install -y "linux-headers-$(uname -r)" || true
      fi
      echo "deb $PPA_URL focal main" | sudo tee /etc/apt/sources.list.d/mysterium.list >/dev/null
      sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys "$PPA_FINGER"
      sudo apt update
      sudo apt install -y wireguard myst
      ;;
  esac

  echo "### Mysterium node installation complete"
  command -v myst
}

install_mysterium_node "$@"
