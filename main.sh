#!/usr/bin/env bash

# ===============================
# HARDENED GRAND NETWORK MANAGER (MULTI-APP SAFE / tun2socks)
# Kernel tuning + per-namespace network isolation + clone-and-run helper
# ===============================

set -euo pipefail

ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true

# Fix CRLF if needed
for f in "$(dirname "$0")"/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

chmod +x ./app/cli ./app/psclient ./app/provider ./app/CastarSDK ./app/honeygain_file/honeygain 2>/dev/null || true

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EARNAPP_SCRIPT="$BASE_DIR/direct_earnapp.sh"
TRAFF_SCRIPT="$BASE_DIR/direct_traff.sh"
UR_SCRIPT="$BASE_DIR/direct_urnetwork.sh"
INSTALL_SCRIPT="$BASE_DIR/install_tun2socks.sh"
MYST_INSTALL_SCRIPT="$BASE_DIR/install_mysterium_node.sh"
MYSTERIUM_SCRIPT="$BASE_DIR/direct_mysterium.sh"
WIPTER_SCRIPT="$BASE_DIR/direct_wipter.sh"
HONEYGAIN_SCRIPT="$BASE_DIR/direct_honeygain.sh"
HONEYGAIN_ACCOUNTS_FILE="$BASE_DIR/honeygain_password.txt"

PIDS=()
EXITING=0
TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
WIPTER_EMAIL="${WIPTER_EMAIL:-${EMAIL:-}}"
WIPTER_PASSWORD="${WIPTER_PASSWORD:-${PASSWORD:-}}"
HONEYGAIN_ACCOUNTS=()

# maps ns name -> numeric index used for subnet allocation
declare -A NS_INDEX=(
  [earnns]=1
  [traffns]=2
  [psns]=3
  [castarns]=4
  [urns]=5
  [wipterns]=6
  [honeyns]=7
)

CREATED_NETNS=()
CREATED_SUBNETS=()

HOST_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[ -n "$HOST_IF" ] || HOST_IF="eth0"

kernel_tune() {
  echo "Applying conservative kernel tuning for high-scale (safe defaults)..."

  sudo modprobe nf_conntrack 2>/dev/null || true
  ulimit -n 2097152 || true
  sudo sysctl -w fs.file-max=1000000 >/dev/null || true
  sudo sysctl -w fs.nr_open=2000000 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_fin_timeout=30 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_max_tw_buckets=200000 >/dev/null || true
  sudo sysctl -w net.netfilter.nf_conntrack_max=262144 >/dev/null || true
  sudo sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=600 >/dev/null || true
  sudo sysctl -w net.core.somaxconn=65535 >/dev/null || true
  sudo sysctl -w net.core.netdev_max_backlog=262144 >/dev/null || true
  sudo sysctl -w net.core.rmem_max=67108864 >/dev/null || true
  sudo sysctl -w net.core.wmem_max=67108864 >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432" >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432" >/dev/null || true
  sudo sysctl -w vm.max_map_count=262144 >/dev/null || true
  sudo sysctl -w vm.swappiness=10 >/dev/null || true
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
  sudo sysctl -w fs.inotify.max_user_instances=1048576 >/dev/null 2>&1 || true
  sudo sysctl -w fs.inotify.max_user_watches=1048576 >/dev/null 2>&1 || true
  sudo sysctl -w fs.inotify.max_queued_events=1048576 >/dev/null 2>&1 || true
  sudo modprobe tcp_bbr 2>/dev/null || true
  sudo sysctl -w net.core.default_qdisc=fq >/dev/null || true
  sudo sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || true

  echo "Kernel tuning applied (conservative)."
}

create_netns_with_veth() {
  local ns="$1"
  local veth_prefix="${2:-veth}"
  local idx="${3:-0}"

  if [ "$idx" -eq 0 ]; then
    idx="${NS_INDEX[$ns]:-0}"
    if [ -z "$idx" ] || [ "$idx" -eq 0 ]; then
      idx=10
      while ip netns list | grep -qw "ns${idx}"; do
        idx=$((idx+1))
      done
    fi
  fi

  if ip netns list | awk '{print $1}' | grep -qw "$ns"; then
    echo "Netns $ns already exists, skipping creation."
    return 0
  fi

  echo "Creating netns $ns with veth prefix ${veth_prefix} idx ${idx}..."
  sudo ip netns add "$ns"
  CREATED_NETNS+=("$ns")

  local host_if="${veth_prefix}h${idx}"
  local ns_if="${veth_prefix}n${idx}"
  local host_ip="10.200.${idx}.1/24"
  local ns_ip="10.200.${idx}.2/24"
  local subnet="10.200.${idx}.0/24"

  sudo ip link add "$host_if" type veth peer name "$ns_if"
  sudo ip link set "$ns_if" netns "$ns"
  sudo ip addr add "$host_ip" dev "$host_if" || true
  sudo ip link set "$host_if" up
  sudo ip netns exec "$ns" ip addr add "$ns_ip" dev "$ns_if"
  sudo ip netns exec "$ns" ip link set "$ns_if" up
  sudo ip netns exec "$ns" ip link set lo up
  sudo ip netns exec "$ns" ip route add default via "10.200.${idx}.1" || true

  sudo mkdir -p "/etc/netns/$ns"
  echo "nameserver 1.1.1.1" | sudo tee /etc/netns/"$ns"/resolv.conf >/dev/null
  echo "nameserver 8.8.8.8" | sudo tee -a /etc/netns/"$ns"/resolv.conf >/dev/null

  sudo iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
  CREATED_SUBNETS+=("$subnet")
  echo "Netns $ns created: host dev $host_if ($host_ip) <-> ns dev $ns_if ($ns_ip)."
}

cleanup() {
  [[ "$EXITING" == "1" ]] && return
  EXITING=1
  echo -e "\nStopping all running services..."

  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true

  for subnet in "${CREATED_SUBNETS[@]:-}"; do
    sudo iptables -t nat -D POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || true
  done

  for ns in "${CREATED_NETNS[@]:-}"; do
    sudo ip netns delete "$ns" 2>/dev/null || true
    sudo rm -rf /etc/netns/"$ns" 2>/dev/null || true
  done
  echo "All services and network namespaces stopped/removed."
  exit 0
}
trap cleanup INT TERM

ask_tokens() {
  echo "========== TOKEN SETUP =========="
  read -rp "Enter Traff token (or leave blank): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (or leave blank): " PS_TOKEN
  read -rp "Enter Castar Key (or leave blank): " CASTAR_KEY
  echo "------ Wipter Credentials ------"
  if [[ -z "${WIPTER_EMAIL:-}" ]]; then
    read -rp "Enter Wipter Email (or leave blank): " WIPTER_EMAIL
  else
    echo "Using Wipter Email from environment."
  fi
  if [[ -z "${WIPTER_PASSWORD:-}" ]]; then
    read -rsp "Enter Wipter Password (hidden, leave blank to skip): " WIPTER_PASSWORD
    echo
  else
    echo "Using Wipter Password from environment."
  fi
  export WIPTER_EMAIL WIPTER_PASSWORD EMAIL="$WIPTER_EMAIL" PASSWORD="$WIPTER_PASSWORD"
  echo "================================="
}

install_dependencies() {
  sudo apt update && sudo apt install -y curl wget unzip iproute2 iptables uuid-runtime jq net-tools git socat
}

install_earnapp() {
  install_dependencies
  wget -qO- https://brightdata.com/static/earnapp/install.sh > /tmp/earnapp.sh && sudo bash /tmp/earnapp.sh
}

install_wipter() {
  echo "Installing Wipter dependencies and Wipter app..."
  sudo apt-get update
  sudo apt-get install -y \
    xvfb \
    dbus \
    dbus-x11 \
    dbus-user-session \
    gnome-keyring \
    libsecret-tools \
    libsecret-1-0 \
    libgtk-3-0 \
    libnss3 \
    libxss1 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libgbm1 \
    libxkbcommon0 libsecret-1-dev \
    xdg-utils \
    fonts-liberation

  sudo apt-get install -y libasound2 || sudo apt-get install -y libasound2t64

  (
    cd /tmp
    wget -O wipter-app-amd64.deb https://provider-assets.wipter.com/latest/linux/x64/wipter-app-amd64.deb
    sudo apt install -y ./wipter-app-amd64.deb
  )

  echo "Wipter install complete."
}
load_honeygain_accounts() {
  HONEYGAIN_ACCOUNTS=()
  if [[ -f "$HONEYGAIN_ACCOUNTS_FILE" ]]; then
    while IFS='|' read -r email password; do
      [[ -n "${email:-}" && -n "${password:-}" ]] || continue
      HONEYGAIN_ACCOUNTS+=("$email|$password")
    done < "$HONEYGAIN_ACCOUNTS_FILE"
  fi
}

declare -a HONEYGAIN_ACCOUNTS=()

save_honeygain_accounts() {
  : > "$HONEYGAIN_ACCOUNTS_FILE"
  chmod 600 "$HONEYGAIN_ACCOUNTS_FILE"
  local account
  for account in "${HONEYGAIN_ACCOUNTS[@]}"; do
    printf '%s\n' "$account" >> "$HONEYGAIN_ACCOUNTS_FILE"
  done
}

collect_honeygain_accounts() {
  local mode="$1"
  local count=1
  local email password

  if [[ "$mode" == "multiple" ]]; then
    while true; do
      read -rp "How many Honeygain accounts do you want to add? " count
      [[ "$count" =~ ^[1-9][0-9]*$ ]] && break
      echo "Please enter a valid number greater than 0."
    done
  fi

  for ((i=1; i<=count; i++)); do
    echo "Honeygain account $i"
    while true; do
      read -rp "Email: " email
      [[ -n "$email" ]] && break
      echo "Email cannot be empty."
    done
    while true; do
      read -rsp "Password: " password
      echo
      [[ -n "$password" ]] && break
      echo "Password cannot be empty."
    done
    HONEYGAIN_ACCOUNTS+=("$email|$password")
  done
}

setup_honeygain_accounts() {
  load_honeygain_accounts

  if (( ${#HONEYGAIN_ACCOUNTS[@]} > 0 )); then
    echo "Found ${#HONEYGAIN_ACCOUNTS[@]} saved Honeygain account(s) in $(basename "$HONEYGAIN_ACCOUNTS_FILE")."
    read -rp "Do you want to use the saved Honeygain accounts? [Y/n]: " reuse_choice
    reuse_choice="${reuse_choice:-Y}"
    if [[ ! "$reuse_choice" =~ ^[Yy]$ ]]; then
      HONEYGAIN_ACCOUNTS=()
    else
      read -rp "Do you want to add more Honeygain accounts before starting? [y/N]: " add_more_choice
      if [[ "$add_more_choice" =~ ^[Yy]$ ]]; then
        collect_honeygain_accounts multiple
      fi
    fi
  fi

  if (( ${#HONEYGAIN_ACCOUNTS[@]} == 0 )); then
    echo "Honeygain setup:"
    echo "1) Single account"
    echo "2) Multiple accounts"
    local setup_choice
    while true; do
      read -rp "Select option [1-2]: " setup_choice
      case "$setup_choice" in
        1) collect_honeygain_accounts single; break ;;
        2) collect_honeygain_accounts multiple; break ;;
        *) echo "Invalid option. Please choose 1 or 2." ;;
      esac
    done
  fi

  if (( ${#HONEYGAIN_ACCOUNTS[@]} == 0 )); then
    echo "No Honeygain accounts configured."
    return 1
  fi

  save_honeygain_accounts
  echo "Saved ${#HONEYGAIN_ACCOUNTS[@]} Honeygain account(s) to $(basename "$HONEYGAIN_ACCOUNTS_FILE")."
}

clone_and_run() {
  local repo_url="$1"
  local app_name="$2"
  local run_cmd="$3"
  local ns_name="${4:-${app_name}ns}"
  local veth_prefix="${5:-${app_name}_veth}"
  local idx="${6:-0}"
  local dest="/opt/apps/$app_name"

  sudo mkdir -p /opt/apps
  if [ ! -d "$dest/.git" ]; then
    echo "Cloning $repo_url -> $dest"
    sudo git clone "$repo_url" "$dest"
    sudo chown -R "$(id -u):$(id -g)" "$dest"
  else
    echo "Repo exists at $dest; pulling latest"
    (cd "$dest" && git pull) || true
  fi

  create_netns_with_veth "$ns_name" "$veth_prefix" "$idx"
  echo "Starting $app_name inside namespace $ns_name..."
  sudo ip netns exec "$ns_name" bash -lc "cd '$dest' && nohup $run_cmd >/tmp/${app_name}.log 2>&1 & echo \$!" \
    | { read -r pid; echo "$pid"; PIDS+=("$pid"); } >/dev/null 2>&1 || true
  echo "$app_name started (check /tmp/${app_name}.log in namespace context)."
}

run_earnapp() {
  create_netns_with_veth "earnns" "earn" "${NS_INDEX[earnns]}"
  echo "Starting EarnApp..."
  sudo BASE_NS=earnns VETH_PREFIX=earn WORKDIR=/tmp/earnapp_multi \
    bash "$EARNAPP_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_traff() {
  if [[ -z "$TRAFF_TOKEN" ]]; then echo "Traff token not set."; return; fi
  create_netns_with_veth "traffns" "traff" "${NS_INDEX[traffns]}"
  local RUNTIME="/tmp/traff_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|--token \".*\"|--token \"$TRAFF_TOKEN\"|g" "$RUNTIME"
  echo "Starting Traff..."
  sudo BASE_NS=traffns VETH_PREFIX=traff WORKDIR=/tmp/traff_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_packetstream() {
  if [[ -z "$PS_TOKEN" ]]; then echo "PacketStream token not set."; return; fi
  create_netns_with_veth "psns" "ps" "${NS_INDEX[psns]}"
  local RUNTIME="/tmp/ps_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|APP_CMD=.*|APP_CMD=( env CID=\"$PS_TOKEN\" PS_IS_DOCKER=true ./app/psclient )|g" "$RUNTIME"
  echo "Starting PacketStream..."
  sudo BASE_NS=psns VETH_PREFIX=ps WORKDIR=/tmp/ps_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_castar() {
  if [[ -z "$CASTAR_KEY" ]]; then echo "Castar key not set."; return; fi
  create_netns_with_veth "castarns" "castar" "${NS_INDEX[castarns]}"
  local RUNTIME="/tmp/castar_runtime.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  sed -i "s|APP_CMD=.*|APP_CMD=( ./app/CastarSDK -key=\"$CASTAR_KEY\" )|g" "$RUNTIME"
  echo "Starting Castar..."
  sudo BASE_NS=castarns VETH_PREFIX=castar WORKDIR=/tmp/castar_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_urnetwork() {
  create_netns_with_veth "urns" "ur" "${NS_INDEX[urns]}"
  echo "Starting UrNetwork..."
  if [[ ! -f "$HOME/.urnetwork/jwt" ]]; then
    ./app/provider auth
  fi
  sudo BASE_NS=urns VETH_PREFIX=ur WORKDIR=/tmp/ur_multi \
    bash "$UR_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_wipter() {
  if [[ ! -x "$WIPTER_SCRIPT" ]]; then
    echo "direct_wipter.sh not found or not executable at $WIPTER_SCRIPT"
    echo "Place direct_wipter.sh in $BASE_DIR and chmod +x it."
    return
  fi
  if [[ -z "${WIPTER_EMAIL:-}" || -z "${WIPTER_PASSWORD:-}" ]]; then
    echo "Wipter credentials not set. Please restart and provide them, or set WIPTER_EMAIL/WIPTER_PASSWORD in environment."
    return
  fi
  create_netns_with_veth "wipterns" "wipter" "${NS_INDEX[wipterns]}"
  echo "Starting Wipter..."
  sudo BASE_NS=wipterns \
       VETH_PREFIX=wipter \
       WORKDIR=/tmp/wipter_multi \
       WIPTER_EMAIL="$WIPTER_EMAIL" \
       WIPTER_PASSWORD="$WIPTER_PASSWORD" \
       EMAIL="$WIPTER_EMAIL" \
       PASSWORD="$WIPTER_PASSWORD" \
       bash "$WIPTER_SCRIPT" proxies.txt &
  PIDS+=($!)
}
run_honeygain() {
  if [[ ! -x "$HONEYGAIN_SCRIPT" ]]; then
    echo "direct_honeygain.sh not found or not executable at $HONEYGAIN_SCRIPT"
    return
  fi
  if [[ ! -x "$BASE_DIR/app/honeygain_file/honeygain" ]]; then
    echo "Honeygain binary missing at app/honeygain_file/honeygain"
    return
  fi

  setup_honeygain_accounts
  if ((${#HONEYGAIN_ACCOUNTS[@]} == 0)); then
    echo "No Honeygain accounts configured."
    return
  fi

  local account_blob
  account_blob=$(printf '%s\n' "${HONEYGAIN_ACCOUNTS[@]}")
  echo "Starting Honeygain with ${#HONEYGAIN_ACCOUNTS[@]} account(s)..."
  sudo BASE_NS=honeyns VETH_PREFIX=honey WORKDIR=/tmp/honeygain_multi HONEYGAIN_ACCOUNTS="$account_blob" \
    bash "$HONEYGAIN_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_mysterium() {
  if [[ ! -x "$MYSTERIUM_SCRIPT" ]]; then
    echo "direct_mysterium.sh not found or not executable at $MYSTERIUM_SCRIPT"
    return
  fi
  echo "Starting Mysterium node instances..."
  sudo BASE_NS=mysterns VETH_PREFIX=myster WORKDIR=/tmp/mysterium_multi \
    MYST_BASE_DIR="$BASE_DIR/myst" \
    bash "$MYSTERIUM_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_honeygain() {
  if [[ ! -x "$HONEYGAIN_SCRIPT" ]]; then
    echo "direct_honeygain.sh not found or not executable at $HONEYGAIN_SCRIPT"
    return
  fi

  if [[ ! -x "$BASE_DIR/app/honeygain_file/honeygain" ]]; then
    echo "Honeygain binary not found or not executable at $BASE_DIR/app/honeygain_file/honeygain"
    return
  fi

  setup_honeygain_accounts || return
  create_netns_with_veth "honeyns" "honey" "${NS_INDEX[honeyns]}"
  echo "Starting Honeygain..."
  sudo BASE_NS=honeyns \
       VETH_PREFIX=honey \
       WORKDIR=/tmp/honeygain_multi \
       HONEYGAIN_ACCOUNTS_FILE="$HONEYGAIN_ACCOUNTS_FILE" \
       bash "$HONEYGAIN_SCRIPT" proxies.txt &
  PIDS+=($!)
}

menu() {
  echo -e "\n====== GRAND NETWORK MANAGER (HARDENED / MULTI-NS) ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Run UrNetwork"
  echo "5) Run Castar"
  echo "6) Install tun2socks"
  echo "7) Install EarnApp Binary"
  echo "8) Install Dependencies"
  echo "9) Run ALL (Safe Mode)"
  echo "V) Install Wipter Binary"
  echo "A) Clone & Run custom repo"
  echo "H) Run Honeygain"
  echo "W) Run Wipter"
  echo "M) Run Mysterium Node"
  echo "I) Install Mysterium Node"
  echo "0) Exit"
  echo "==============================================="
}

kernel_tune
ask_tokens

while true; do
  menu
  read -rp "Select option: " opt || cleanup
  case "$opt" in
    1) run_earnapp ; wait ;;
    2) run_traff ; wait ;;
    3) run_packetstream ; wait ;;
    4) run_urnetwork ; wait ;;
    5) run_castar ; wait ;;
    6) sudo bash "$INSTALL_SCRIPT" ; wait ;;
    7) install_earnapp ; wait ;;
    8) install_dependencies ; wait ;;
    V|v) install_wipter ; wait ;;
    9)
      run_earnapp
      run_traff
      run_packetstream
      run_urnetwork
      run_castar
      run_honeygain
      run_wipter
      run_mysterium
      echo "All services running (staggered safe mode). Press Ctrl+C to stop."
      wait
      ;;
    A|a)
      read -rp "Repo URL: " repo
      read -rp "App name (short): " aname
      read -rp "Run command (relative to repo root, e.g. ./start.sh): " runcmd
      clone_and_run "$repo" "$aname" "$runcmd"
      ;;
    H|h) run_honeygain ; wait ;;
    W|w) run_wipter ; wait ;;
    M|m) run_mysterium ; wait ;;
    I|i) sudo bash "$MYST_INSTALL_SCRIPT" ; wait ;;
    0) cleanup ;;
    *) echo "Invalid option." ;;
  esac
done
