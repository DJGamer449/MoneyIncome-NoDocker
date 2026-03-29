#!/usr/bin/env bash

set -euo pipefail

if [[ ${EUID:-0} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="$BASE_DIR/install_expressvpn.sh"
MYST_INSTALL_SCRIPT="$BASE_DIR/install_mysterium_node.sh"
HONEYGAIN_ACCOUNTS_FILE="$BASE_DIR/honeygain_password.txt"

RUNTIME_ROOT="/opt/moneyincome_runtime"
mkdir -p "$RUNTIME_ROOT"

# Regions are consumed in order; when exhausted, loop from the beginning.
REGIONS=(
  usa-san-francisco usa-new-jersey-2 usa-lincoln-park usa-houston usa-tampa-1 usa-new-jersey-3 usa-brooklyn usa-denver
  usa-dallas usa-atlanta usa-seattle usa-miami-2 usa-salt-lake-city usa-santa-monica usa-washington-dc usa-new-jersey-1
  usa-boston usa-birmingham usa-anchorage usa-little-rock usa-bridgeport usa-wilmington usa-honolulu usa-boise
  usa-indianapolis usa-des-moines usa-wichita usa-louisville usa-new-orleans usa-portland-maine usa-baltimore usa-detroit
  usa-minneapolis usa-jackson usa-st.-louis usa-billings usa-omaha usa-las-vegas usa-manchester usa-charlotte
  usa-fargo usa-columbus usa-oklahoma-city usa-portland-oregon usa-philadelphia usa-providence
  usa-charleston-south-carolina usa-sioux-falls usa-nashville usa-burlington usa-virginia-beach
  usa-charleston-west-virginia usa-milwaukee usa-cheyenne usa-miami usa-los-angeles-1 usa-los-angeles-2
  usa-los-angeles-5 usa-los-angeles-3 usa-new-york usa-chicago usa-phoenix usa-albuquerque
  costa-rica thailand greece
  france-strasbourg france-paris-1 france-alsace france-marseille france-paris-2
  israel iceland
  singapore-cbd singapore-jurong singapore-marina-bay
  taiwan-3 south-africa
  switzerland switzerland-2
  bulgaria malaysia indonesia new-zealand
  hong-kong-2 hong-kong-1 bahamas vietnam
  croatia liechtenstein luxembourg moldova slovenia latvia cyprus chile albania slovakia uzbekistan isle-of-man estonia
  colombia mexico kazakhstan malta georgia mongolia algeria uruguay guatemala peru venezuela ecuador
  serbia north-macedonia bosnia-and-herzegovina
  uk-midlands uk-east-london uk-tottenham uk-london uk-docklands uk-wembley
  india-via-uk india-via-singapore
  australia-melbourne australia-sydney-2 australia-brisbane australia-perth australia-woolloomooloo australia-sydney australia-adelaide
  italy-milan italy-cosenza italy-naples
  netherlands-rotterdam netherlands-the-hague netherlands-amsterdam
  brazil-2 brazil philippines
  canada-toronto-2 canada-vancouver canada-montreal canada-toronto
  macau cambodia kenya
  andorra armenia belarus monaco jersey montenegro
  bangladesh bhutan brunei laos myanmar nepal pakistan sri-lanka panama
  sweden-2 sweden austria
  germany-nuremberg germany-frankfurt-1 germany-frankfurt-3
  spain-barcelona spain-madrid spain-barcelona-2
  japan-yokohama japan-tokyo japan-shibuya japan-osaka
  bolivia guam ghana dominican-republic jamaica puerto-rico bermuda trinidad-and-tobago cayman-islands cuba honduras
  lebanon morocco united-arab-emirates azerbaijan
  portugal poland ireland finland lithuania czech-republic
  south-korea-2 denmark egypt belgium romania ukraine
  argentina turkey norway hungary
)

HOST_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
HOST_IF="${HOST_IF:-eth0}"
EXPRESSVPN_CODE=""
TRAFF_TOKEN=""
PS_TOKEN=""
CASTAR_KEY=""
WIPTER_EMAIL=""
WIPTER_PASSWORD=""
declare -a HONEYGAIN_ACCOUNTS=()

cleanup() {
  set +e
  echo "Cleaning up created namespaces..."
  for ns in $(ip netns list | awk '{print $1}' | grep -E '^(earnns|traffns|psns|castarns|urns|wipterns|honeyns|mysterns)[0-9]+$' || true); do
    ip netns del "$ns" >/dev/null 2>&1 || true
    rm -rf "/etc/netns/$ns" >/dev/null 2>&1 || true
  done
}
trap cleanup INT TERM

install_dependencies() {
  sudo apt update
  sudo apt install -y curl wget unzip iproute2 iptables uuid-runtime jq net-tools git socat util-linux
}

ask_credentials() {
  echo "========== EXPRESSVPN SETUP =========="
  read -rp "Enter ExpressVPN activation key: " EXPRESSVPN_CODE
  echo "======================================"
  read -rp "Enter Traff token (or leave blank): " TRAFF_TOKEN
  read -rp "Enter PacketStream CID token (or leave blank): " PS_TOKEN
  read -rp "Enter Castar Key (or leave blank): " CASTAR_KEY
  read -rp "Enter Wipter Email (or leave blank): " WIPTER_EMAIL
  read -rsp "Enter Wipter Password (hidden, leave blank): " WIPTER_PASSWORD
  echo
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
  for entry in "${HONEYGAIN_ACCOUNTS[@]:-}"; do
    printf '%s\n' "$entry" >> "$HONEYGAIN_ACCOUNTS_FILE"
  done
}

prompt_honeygain_account() {
  local email password
  read -rp "Enter Honeygain email: " email
  read -rsp "Enter Honeygain password: " password
  echo
  [[ -n "$email" && -n "$password" ]] && HONEYGAIN_ACCOUNTS+=("$email|$password")
}

prompt_instance_count() {
  local count
  while true; do
    read -rp "How many instances do you want to run? " count
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) && { echo "$count"; return 0; }
    echo "Enter a positive integer."
  done
}

create_isolated_ns() {
  local ns="$1" idx="$2" prefix="$3"
  local host_if="${prefix}${idx}h" ns_if="${prefix}${idx}n"
  local host_ip="10.210.${idx}.1/24" ns_ip="10.210.${idx}.2/24" subnet="10.210.${idx}.0/24"

  ip netns add "$ns" 2>/dev/null || true
  ip link add "$host_if" type veth peer name "$ns_if" 2>/dev/null || true
  ip link set "$ns_if" netns "$ns"
  ip addr add "$host_ip" dev "$host_if" 2>/dev/null || true
  ip link set "$host_if" up
  ip netns exec "$ns" ip addr add "$ns_ip" dev "$ns_if" 2>/dev/null || true
  ip netns exec "$ns" ip link set "$ns_if" up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route replace default via "10.210.${idx}.1" dev "$ns_if"
  mkdir -p "/etc/netns/$ns/expressvpn"
  # expressvpn startup bind-mounts this namespace path onto /etc/expressvpn.
  # Ensure bind target exists to avoid:
  # "Bind /etc/netns/<ns>/expressvpn -> /etc/expressvpn failed: No such file or directory"
  mkdir -p "/etc/expressvpn"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "/etc/netns/$ns/resolv.conf"
  iptables -t nat -C POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$subnet" -o "$HOST_IF" -j MASQUERADE
  ip netns exec "$ns" groupadd -f expressvpn || true
}

region_for_index() {
  local idx="$1"
  local n="${#REGIONS[@]}"
  echo "${REGIONS[$(( (idx - 1) % n ))]}"
}

start_expressvpn_in_ns() {
  local ns="$1" region="$2" inst_dir="$3"
  mkdir -p "$inst_dir"
  ip netns exec "$ns" bash -lc "export CODE='$EXPRESSVPN_CODE'; export SERVER='$region'; nohup /opt/expressvpn/start.sh > '$inst_dir/expressvpn.log' 2>&1 &"
  sleep 2
}

run_instances() {
  local app_name="$1" base_ns="$2" prefix="$3" command_template="$4"
  local count
  count="$(prompt_instance_count)"

  for ((i=1; i<=count; i++)); do
    local ns="${base_ns}${i}"
    local region inst_dir cmd
    region="$(region_for_index "$i")"
    inst_dir="$RUNTIME_ROOT/${app_name}/instance_${i}"
    mkdir -p "$inst_dir"

    echo "[$app_name#$i] Creating isolated namespace $ns (region=$region)..."
    create_isolated_ns "$ns" "$i" "$prefix"
    start_expressvpn_in_ns "$ns" "$region" "$inst_dir"

    cmd="$command_template"
    cmd="${cmd//\{INSTANCE\}/$i}"
    cmd="${cmd//\{DIR\}/$inst_dir}"

    echo "[$app_name#$i] Starting app in $ns"
    ip netns exec "$ns" bash -lc "export HOME='$inst_dir/home'; mkdir -p \"\$HOME\"; cd '$BASE_DIR'; nohup $cmd > '$inst_dir/app.log' 2>&1 &"
  done

  echo "$app_name instances started. Logs under $RUNTIME_ROOT/$app_name/instance_*/"
}

run_earnapp() { run_instances "earnapp" "earnns" "earn" "earnapp start"; }
run_traff() {
  [[ -n "$TRAFF_TOKEN" ]] || { echo "Traff token missing."; return; }
  run_instances "traff" "traffns" "traff" "./app/cli start accept --token '$TRAFF_TOKEN'"
}
run_packetstream() {
  [[ -n "$PS_TOKEN" ]] || { echo "PacketStream token missing."; return; }
  run_instances "packetstream" "psns" "ps" "env CID='$PS_TOKEN' PS_IS_DOCKER=true ./app/psclient"
}
run_castar() {
  [[ -n "$CASTAR_KEY" ]] || { echo "Castar key missing."; return; }
  run_instances "castar" "castarns" "castar" "./app/CastarSDK -key='$CASTAR_KEY'"
}
run_urnetwork() {
  [[ -f "$HOME/.urnetwork/jwt" ]] || ./app/provider auth
  run_instances "urnetwork" "urns" "ur" "./app/provider provide"
}
run_wipter() {
  [[ -n "$WIPTER_EMAIL" && -n "$WIPTER_PASSWORD" ]] || { echo "Wipter credentials missing."; return; }
  run_instances "wipter" "wipterns" "wipter" "WIPTER_EMAIL='$WIPTER_EMAIL' WIPTER_PASSWORD='$WIPTER_PASSWORD' ./direct_wipter.sh /dev/null"
}
run_honeygain() {
  load_honeygain_accounts
  ((${#HONEYGAIN_ACCOUNTS[@]} > 0)) || prompt_honeygain_account
  save_honeygain_accounts
  local creds="${HONEYGAIN_ACCOUNTS[0]}"
  local email="${creds%%|*}" pass="${creds##*|}"
  run_instances "honeygain" "honeyns" "honey" "./app/honeygain_file/honeygain -tou-accept -email '$email' -pass '$pass' -device 'hg-{INSTANCE}'"
}
run_mysterium() {
  run_instances "mysterium" "mysterns" "myst" "myst --agreed-terms-and-conditions service --data-dir '{DIR}/myst'"
}

menu() {
  cat <<'MENU'
====== GRAND NETWORK MANAGER (EXPRESSVPN / MULTI-NS) ======
1) Run EarnApp
2) Run Traff
3) Run PacketStream
4) Run UrNetwork
5) Run Castar
6) Install ExpressVPN runtime
7) Install EarnApp Binary
8) Install Dependencies
9) Run ALL
H) Run Honeygain
W) Run Wipter
M) Run Mysterium Node
I) Install Mysterium Node
0) Exit
===========================================================
MENU
}

install_earnapp() {
  install_dependencies
  wget -qO- https://brightdata.com/static/earnapp/install.sh > /tmp/earnapp.sh && sudo bash /tmp/earnapp.sh
}

kernel_tune() {
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
}

handle_option() {
  local opt="$1"
  case "$opt" in
    1) run_earnapp ;;
    2) run_traff ;;
    3) run_packetstream ;;
    4) run_urnetwork ;;
    5) run_castar ;;
    6) bash "$INSTALL_SCRIPT" ;;
    7) install_earnapp ;;
    8) install_dependencies ;;
    9) run_earnapp; run_traff; run_packetstream; run_urnetwork; run_castar; run_honeygain; run_wipter; run_mysterium ;;
    H|h) run_honeygain ;;
    W|w) run_wipter ;;
    M|m) run_mysterium ;;
    I|i) bash "$MYST_INSTALL_SCRIPT" ;;
    0) cleanup; exit 0 ;;
    *) echo "Invalid option." ; return 1 ;;
  esac
}

kernel_tune
ask_credentials

if [[ $# -gt 0 ]]; then
  handle_option "$1"
  exit 0
fi

while true; do
  menu
  read -rp "Select option: " opt
  handle_option "$opt"
done
