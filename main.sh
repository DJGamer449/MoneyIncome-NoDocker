#!/usr/bin/env bash

# ===============================
# HARDENED GRAND NETWORK MANAGER (MULTI-APP SAFE)
# Kernel tuning + per-namespace network isolation + clone-and-run helper
# ===============================

set -euo pipefail

# Fix CRLF if needed
for f in "$(dirname "$0")"/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

chmod +x ./app/cli ./app/psclient ./app/provider ./app/CastarSDK ./app/honeygain_file/honeygain 2>/dev/null || true

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
EARNAPP_SCRIPT="$BASE_DIR/direct_earnapp.sh"
TRAFF_SCRIPT="$BASE_DIR/direct_traff.sh"
CASTAR_SCRIPT="$BASE_DIR/direct_castar.sh"
UR_SCRIPT="$BASE_DIR/direct_urnetwork.sh"
MYST_INSTALL_SCRIPT="$BASE_DIR/install_mysterium_node.sh"
WIPTER_SCRIPT="$BASE_DIR/direct_wipter.sh"
HONEYGAIN_SCRIPT="$BASE_DIR/direct_honeygain.sh"
MYSTERIUM_SCRIPT="$BASE_DIR/direct_mysterium.sh"
HONEYGAIN_ACCOUNTS_FILE="$BASE_DIR/honeygain_password.txt"

PIDS=()
EXITING=0
TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
WIPTER_EMAIL=""
WIPTER_PASSWORD=""
HONEYGAIN_ACCOUNTS=()
EXPRESSVPN_BIN_DIR="$BASE_DIR/app/expressvpn/bin"
EXPRESSVPN_DAEMON="$EXPRESSVPN_BIN_DIR/expressvpn-daemon"
EXPRESSVPN_CTL="$EXPRESSVPN_BIN_DIR/expressvpnctl"
EXPRESSVPN_ACTIVATION=""
EXPRESSVPN_PROTOCOL="lightway_udp"
EXPRESSVPN_INSTANCE_COUNT=1
EXPRESSVPN_REGIONS=()
DEFAULT_EXPRESSVPN_REGIONS=(
  usa-san-francisco usa-new-jersey-2 usa-lincoln-park usa-houston usa-tampa-1 usa-new-jersey-3 usa-brooklyn usa-denver
  usa-dallas usa-atlanta usa-seattle usa-miami-2 usa-salt-lake-city usa-santa-monica usa-washington-dc usa-new-jersey-1
  usa-boston usa-birmingham usa-anchorage usa-little-rock usa-bridgeport usa-wilmington usa-honolulu usa-boise
  usa-indianapolis usa-des-moines usa-wichita usa-louisville usa-new-orleans usa-portland-maine usa-baltimore usa-detroit
  usa-minneapolis usa-jackson usa-st.-louis usa-billings usa-omaha usa-las-vegas usa-manchester usa-charlotte
  usa-fargo usa-columbus usa-oklahoma-city usa-portland-oregon usa-philadelphia usa-providence
  usa-charleston-south-carolina usa-sioux-falls usa-nashville usa-burlington usa-virginia-beach
  usa-charleston-west-virginia usa-milwaukee usa-cheyenne usa-miami usa-los-angeles-1 usa-los-angeles-2
  usa-los-angeles-5 usa-los-angeles-3 usa-new-york usa-chicago usa-phoenix usa-albuquerque
  costa-rica thailand greece france-strasbourg france-paris-1 france-alsace france-marseille france-paris-2 israel iceland
  singapore-cbd singapore-jurong singapore-marina-bay taiwan-3 south-africa switzerland switzerland-2 bulgaria malaysia indonesia
  new-zealand hong-kong-2 hong-kong-1 bahamas vietnam croatia liechtenstein luxembourg moldova slovenia latvia cyprus chile
  albania slovakia uzbekistan isle-of-man estonia colombia mexico kazakhstan malta georgia mongolia algeria uruguay guatemala peru
  venezuela ecuador serbia north-macedonia bosnia-and-herzegovina uk-midlands uk-east-london uk-tottenham uk-london uk-docklands
  uk-wembley "india-(via-uk)" "india-(via-singapore)" australia-melbourne australia-sydney-2 australia-brisbane australia-perth
  australia-woolloomooloo australia-sydney australia-adelaide italy-milan italy-cosenza italy-naples netherlands-rotterdam
  netherlands-the-hague netherlands-amsterdam brazil-2 brazil philippines canada-toronto-2 canada-vancouver canada-montreal
  canada-toronto macau cambodia kenya andorra armenia belarus monaco jersey montenegro bangladesh bhutan brunei laos myanmar nepal
  pakistan sri-lanka panama sweden-2 sweden austria germany-nuremberg germany-frankfurt-1 germany-frankfurt-3 spain-barcelona
  spain-madrid spain-barcelona-2 japan-yokohama japan-tokyo japan-shibuya japan-osaka bolivia guam ghana dominican-republic
  jamaica puerto-rico bermuda trinidad-and-tobago cayman-islands cuba honduras lebanon morocco united-arab-emirates azerbaijan
  portugal poland ireland finland lithuania czech-republic south-korea-2 denmark egypt belgium romania ukraine argentina turkey norway hungary
)

# maps ns name -> numeric index used for subnet allocation
declare -A NS_INDEX=(
  [earnns]=1
  [traffns]=2
  [psns]=3
  [castarns]=4
  [urns]=5
  [wipterns]=6
  [honeyns]=7
  [mysterns]=8
)

CREATED_NETNS=()
CREATED_SUBNETS=()

HOST_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
[ -n "$HOST_IF" ] || HOST_IF="eth0"

kernel_tune() {
  echo "Applying conservative kernel tuning for high-scale (safe defaults)..."
  sudo modprobe nf_conntrack 2>/dev/null || true
  ulimit -n 2097152 2>/dev/null || true
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
  :
}

stop_tracked_pids() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${PIDS[@]:-}"; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${PIDS[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done
}

cleanup() {
  [[ "$EXITING" == "1" ]] && return
  EXITING=1
  echo -e "\nStopping all running services..."
  stop_tracked_pids
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


ask_expressvpn_setup() {
  echo "========== EXPRESSVPN SETUP =========="
  if [[ ! -x "$EXPRESSVPN_DAEMON" || ! -x "$EXPRESSVPN_CTL" ]]; then
    echo "ExpressVPN binaries not found/executable in $EXPRESSVPN_BIN_DIR"
    echo "Required: expressvpn-daemon and expressvpnctl"
    exit 1
  fi
  while true; do
    read -rsp "Enter ExpressVPN activation key: " EXPRESSVPN_ACTIVATION
    echo
    [[ -n "$EXPRESSVPN_ACTIVATION" ]] && break
    echo "Activation key cannot be empty."
  done
  while true; do
    read -rp "How many VPN instances do you want to run? [1+]: " EXPRESSVPN_INSTANCE_COUNT
    [[ "$EXPRESSVPN_INSTANCE_COUNT" =~ ^[0-9]+$ ]] && (( EXPRESSVPN_INSTANCE_COUNT >= 1 )) && break
    echo "Please enter a number >= 1."
  done
  read -rp "ExpressVPN protocol [lightway_udp]: " EXPRESSVPN_PROTOCOL
  EXPRESSVPN_PROTOCOL="${EXPRESSVPN_PROTOCOL:-lightway_udp}"
  EXPRESSVPN_REGIONS=()
  local i region default_region total choose_specific_region
  read -rp "Select specific region for each instance? [y/N]: " choose_specific_region
  total=${#DEFAULT_EXPRESSVPN_REGIONS[@]}
  for ((i=1; i<=EXPRESSVPN_INSTANCE_COUNT; i++)); do
    default_region="${DEFAULT_EXPRESSVPN_REGIONS[$(((i-1)%total))]}"
    if [[ "$choose_specific_region" =~ ^[Yy]$ ]]; then
      read -rp "Region for instance ${i} [${default_region}]: " region
      region="${region:-$default_region}"
    else
      region="$default_region"
    fi
    EXPRESSVPN_REGIONS+=("$region")
  done
}

start_expressvpn_in_ns() {
  local ns="$1"
  local region="$2"
  local runtime_root="/tmp/expressvpn/${ns}"
  sudo mkdir -p "$runtime_root" "$runtime_root/home" "$runtime_root/run" "$runtime_root/tmp"
  sudo chmod 700 "$runtime_root/home"
  sudo ip netns exec "$ns" bash -lc "
    set +e
    groupadd -f expressvpn >/dev/null 2>&1 || true
    export HOME='$runtime_root/home'
    export TMPDIR='$runtime_root/tmp'
    export XDG_RUNTIME_DIR='$runtime_root/run'
    export PATH='$EXPRESSVPN_BIN_DIR':\$PATH
    nohup '$EXPRESSVPN_DAEMON' >'$runtime_root/daemon.log' 2>&1 &
    sleep 2
    '$EXPRESSVPN_CTL' background enable || true
    '$EXPRESSVPN_CTL' set networklock true
    '$EXPRESSVPN_CTL' set region '$region'
    '$EXPRESSVPN_CTL' set protocol '$EXPRESSVPN_PROTOCOL'
    '$EXPRESSVPN_CTL' login <(echo '$EXPRESSVPN_ACTIVATION') || true
    '$EXPRESSVPN_CTL' connect || true
  "
}

ask_tokens() {
  echo "========== TOKEN SETUP =========="
  read -rp "Enter Traff token (or leave blank): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (or leave blank): " PS_TOKEN
  read -rp "Enter Castar Key (or leave blank): " CASTAR_KEY
  echo "------ Wipter Credentials ------"
  read -rp "Enter Wipter Email (or leave blank): " WIPTER_EMAIL
  read -rsp "Enter Wipter Password (hidden, leave blank to skip): " WIPTER_PASSWORD
  echo
  echo "================================="
}

install_dependencies() {
  sudo apt update && sudo apt install -y curl wget unzip iproute2 iptables uuid-runtime jq net-tools git socat
}

install_earnapp() {
  install_dependencies
  wget -qO- https://brightdata.com/static/earnapp/install.sh > /tmp/earnapp.sh && sudo bash /tmp/earnapp.sh
}

load_honeygain_accounts() {
  HONEYGAIN_ACCOUNTS=()
  [[ -f "$HONEYGAIN_ACCOUNTS_FILE" ]] || return 0
  while IFS='|' read -r email password; do
    [[ -n "${email:-}" && -n "${password:-}" ]] || continue
    HONEYGAIN_ACCOUNTS+=("${email}|${password}")
  done < "$HONEYGAIN_ACCOUNTS_FILE"
}

save_honeygain_accounts() {
  : > "$HONEYGAIN_ACCOUNTS_FILE"
  chmod 600 "$HONEYGAIN_ACCOUNTS_FILE"
  local entry
  for entry in "${HONEYGAIN_ACCOUNTS[@]:-}"; do
    printf '%s\n' "$entry" >> "$HONEYGAIN_ACCOUNTS_FILE"
  done
}

prompt_honeygain_account() {
  local email password
  while true; do
    read -rp "Enter Honeygain email: " email
    [[ -n "$email" ]] && break
    echo "Email cannot be empty."
  done
  while true; do
    read -rsp "Enter Honeygain password: " password
    echo
    [[ -n "$password" ]] && break
    echo "Password cannot be empty."
  done
  HONEYGAIN_ACCOUNTS+=("${email}|${password}")
}

setup_honeygain_accounts() {
  load_honeygain_accounts

  echo "------ Honeygain Account Setup ------"
  if ((${#HONEYGAIN_ACCOUNTS[@]} > 0)); then
    echo "Saved Honeygain accounts found: ${#HONEYGAIN_ACCOUNTS[@]}"
    local idx=1 entry email
    for entry in "${HONEYGAIN_ACCOUNTS[@]}"; do
      email="${entry%%|*}"
      echo "  ${idx}) ${email}"
      idx=$((idx+1))
    done
    read -rp "Use saved accounts? [Y/n]: " use_saved
    if [[ "$use_saved" =~ ^[Nn]$ ]]; then
      HONEYGAIN_ACCOUNTS=()
    else
      read -rp "Add more accounts to previous setup? [y/N]: " add_more_saved
      if [[ "$add_more_saved" =~ ^[Yy]$ ]]; then
        while true; do
          prompt_honeygain_account
          read -rp "Add another Honeygain account? [y/N]: " another
          [[ "$another" =~ ^[Yy]$ ]] || break
        done
      fi
    fi
  fi

  if ((${#HONEYGAIN_ACCOUNTS[@]} == 0)); then
    local mode
    while true; do
      echo "1) Single account"
      echo "2) Multiple accounts"
      read -rp "Choose Honeygain mode [1-2]: " mode
      case "$mode" in
        1)
          prompt_honeygain_account
          break
          ;;
        2)
          while true; do
            prompt_honeygain_account
            read -rp "Add another Honeygain account? [y/N]: " another_multi
            [[ "$another_multi" =~ ^[Yy]$ ]] || break
          done
          break
          ;;
        *) echo "Invalid option." ;;
      esac
    done
  fi

  save_honeygain_accounts
  echo "Honeygain accounts ready: ${#HONEYGAIN_ACCOUNTS[@]}"
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
  local region_idx=$(( idx > 0 ? idx - 1 : 0 ))
  local region="${EXPRESSVPN_REGIONS[$region_idx]:-${EXPRESSVPN_REGIONS[0]}}"
  start_expressvpn_in_ns "$ns_name" "$region"
  echo "Starting $app_name inside namespace $ns_name..."
  sudo ip netns exec "$ns_name" bash -lc "cd '$dest' && nohup $run_cmd >/tmp/${app_name}.log 2>&1 & echo \$!" \
    | { read -r pid; echo "$pid"; PIDS+=("$pid"); } >/dev/null 2>&1 || true
  echo "$app_name started (check /tmp/${app_name}.log in namespace context)."
}

run_earnapp() {
  create_netns_with_veth "earnns" "earn" "${NS_INDEX[earnns]}"
  start_expressvpn_in_ns "earnns" "${EXPRESSVPN_REGIONS[0]}"
  echo "Starting EarnApp..."
  sudo BASE_NS=earnns VETH_PREFIX=earn WORKDIR=/tmp/earnapp_multi \
    bash "$EARNAPP_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_traff() {
  if [[ -z "$TRAFF_TOKEN" ]]; then echo "Traff token not set."; return; fi
  create_netns_with_veth "traffns" "traff" "${NS_INDEX[traffns]}"
  start_expressvpn_in_ns "traffns" "${EXPRESSVPN_REGIONS[0]}"
  local RUNTIME="/tmp/traff_runtime.sh"
  local LIB_RUNTIME="/tmp/direct_expressvpn_lib.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  cp "$BASE_DIR/direct_expressvpn_lib.sh" "$LIB_RUNTIME"
  echo "Starting Traff..."
  sudo BASE_DIR=/tmp TRAFF_TOKEN="$TRAFF_TOKEN" BASE_NS=traffns VETH_PREFIX=traff WORKDIR=/tmp/traff_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_packetstream() {
  if [[ -z "$PS_TOKEN" ]]; then echo "PacketStream token not set."; return; fi
  create_netns_with_veth "psns" "ps" "${NS_INDEX[psns]}"
  start_expressvpn_in_ns "psns" "${EXPRESSVPN_REGIONS[0]}"
  local RUNTIME="/tmp/ps_runtime.sh"
  local LIB_RUNTIME="/tmp/direct_expressvpn_lib.sh"
  cp "$TRAFF_SCRIPT" "$RUNTIME"
  cp "$BASE_DIR/direct_expressvpn_lib.sh" "$LIB_RUNTIME"
  sed -i "s|APP_CMD=.*|APP_CMD=( env CID=\"$PS_TOKEN\" PS_IS_DOCKER=true ./app/psclient )|g" "$RUNTIME"
  echo "Starting PacketStream..."
  sudo BASE_DIR=/tmp BASE_NS=psns VETH_PREFIX=ps WORKDIR=/tmp/ps_multi \
    bash "$RUNTIME" proxies.txt &
  PIDS+=($!)
}

run_castar() {
  if [[ -z "$CASTAR_KEY" ]]; then echo "Castar key not set."; return; fi
  create_netns_with_veth "castarns" "castar" "${NS_INDEX[castarns]}"
  start_expressvpn_in_ns "castarns" "${EXPRESSVPN_REGIONS[0]}"
  echo "Starting Castar..."
  sudo CASTAR_KEY="$CASTAR_KEY" BASE_NS=castarns VETH_PREFIX=castar WORKDIR=/tmp/castar_multi \
    bash "$CASTAR_SCRIPT" proxies.txt &
  PIDS+=($!)
}

run_urnetwork() {
  create_netns_with_veth "urns" "ur" "${NS_INDEX[urns]}"
  start_expressvpn_in_ns "urns" "${EXPRESSVPN_REGIONS[0]}"
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
  start_expressvpn_in_ns "wipterns" "${EXPRESSVPN_REGIONS[0]}"
  echo "Starting Wipter..."
  sudo BASE_NS=wipterns VETH_PREFIX=wipter WORKDIR=/tmp/wipter_multi WIPTER_EMAIL="$WIPTER_EMAIL" WIPTER_PASSWORD="$WIPTER_PASSWORD" \
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

  create_netns_with_veth "honeyns" "honey" "${NS_INDEX[honeyns]}"
  start_expressvpn_in_ns "honeyns" "${EXPRESSVPN_REGIONS[0]}"
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
  create_netns_with_veth "mysterns" "myster" "${NS_INDEX[mysterns]}"
  start_expressvpn_in_ns "mysterns" "${EXPRESSVPN_REGIONS[0]}"
  echo "Starting Mysterium node instances..."
  sudo BASE_NS=mysterns VETH_PREFIX=myster WORKDIR=/tmp/mysterium_multi \
    MYST_BASE_DIR="$BASE_DIR/myst" \
    bash "$MYSTERIUM_SCRIPT" proxies.txt &
  PIDS+=($!)
}

menu() {
  echo -e "\n====== GRAND NETWORK MANAGER (HARDENED / MULTI-NS) ======"
  echo "1) Run EarnApp"
  echo "2) Run Traff"
  echo "3) Run PacketStream"
  echo "4) Run UrNetwork"
  echo "5) Run Castar"
  echo "6) Validate ExpressVPN binaries"
  echo "7) Install EarnApp Binary"
  echo "8) Install Dependencies"
  echo "9) Run ALL (Safe Mode)"
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
ask_expressvpn_setup

while true; do
  menu
  read -rp "Select option: " opt || cleanup
  case "$opt" in
    1) run_earnapp ; wait ;;
    2) run_traff ; wait ;;
    3) run_packetstream ; wait ;;
    4) run_urnetwork ; wait ;;
    5) run_castar ; wait ;;
    6) [[ -x "$EXPRESSVPN_DAEMON" && -x "$EXPRESSVPN_CTL" ]] && echo "ExpressVPN binaries OK at $EXPRESSVPN_BIN_DIR" || echo "ExpressVPN binaries missing" ; wait ;;
    7) install_earnapp ; wait ;;
    8) install_dependencies ; wait ;;
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
