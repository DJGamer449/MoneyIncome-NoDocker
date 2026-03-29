#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$BASE_DIR/expressvpn_regions.sh"

APP_NAME="${1:-}"
APP_CMD="${2:-}"
if [[ -z "$APP_NAME" || -z "$APP_CMD" ]]; then
  echo "Usage: $0 <app_name> <app_cmd>"
  exit 1
fi

read -rsp "Enter ExpressVPN activation key: " EXPRESSVPN_CODE
echo
[[ -n "$EXPRESSVPN_CODE" ]] || { echo "Activation key is required."; exit 1; }

read -rp "How many ${APP_NAME} instances do you want to run? " INSTANCE_COUNT
[[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "Instance count must be a positive integer."; exit 1; }
(( INSTANCE_COUNT > 0 )) || { echo "Instance count must be > 0."; exit 1; }

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required. Install docker and retry."
  exit 1
fi

RUNTIME_ROOT="$BASE_DIR/runtime/expressvpn/${APP_NAME}"
mkdir -p "$RUNTIME_ROOT"

for ((i=1; i<=INSTANCE_COUNT; i++)); do
  region_idx=$(( (i - 1) % ${#EXPRESSVPN_REGIONS[@]} ))
  region="${EXPRESSVPN_REGIONS[$region_idx]}"

  name="${APP_NAME}-expressvpn-${i}"
  inst_dir="$RUNTIME_ROOT/instance-${i}"
  mkdir -p "$inst_dir"

  cat > "$inst_dir/instance.env" <<ENV
CONTAINER_NAME=${name}
INSTANCE=${i}
REGION=${region}
APP_NAME=${APP_NAME}
ENV

  cat > "$inst_dir/run.sh" <<RUN
#!/usr/bin/env bash
set -euo pipefail
cd /workspace/app
exec ${APP_CMD}
RUN
  chmod +x "$inst_dir/run.sh"

  echo "[$APP_NAME#$i] region=$region"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d \
    --name "$name" \
    --cap-add=NET_ADMIN \
    --cap-add=SYS_PTRACE \
    --device=/dev/net/tun \
    --restart unless-stopped \
    -e CODE="$EXPRESSVPN_CODE" \
    -e SERVER="$region" \
    -e PROTOCOL=lightwayudp \
    -e NETWORK=on \
    -e ALLOW_LAN=false \
    -e SOCKS=off \
    -e CONTROL_SERVER=off \
    -e METRICS_PROMETHEUS=off \
    -v "$BASE_DIR:/workspace/app" \
    -v "$inst_dir:/instance" \
    misioslav/expressvpn:latest \
    /bin/bash -lc "/instance/run.sh" > "$inst_dir/container.id"

  docker logs "$name" > "$inst_dir/container.log" 2>&1 || true
  echo "$name" >> "$RUNTIME_ROOT/containers.list"
done

echo "Started $INSTANCE_COUNT isolated ${APP_NAME} instance(s)."
echo "Per-instance files: $RUNTIME_ROOT/instance-*/"
echo "Containers list: $RUNTIME_ROOT/containers.list"
