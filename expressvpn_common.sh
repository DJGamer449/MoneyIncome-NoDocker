#!/usr/bin/env bash
set -euo pipefail

EXPRESSVPN_REGIONS=(
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
'india-(via-uk)' 'india-(via-singapore)'
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

ensure_expressvpn_installed() {
  if [[ -d ./app/expressvpn ]]; then
    mkdir -p /opt/expressvpn
    cp -a ./app/expressvpn/. /opt/expressvpn/
  fi
  if [[ -f ./app/expressvpn/bin/expressvpnctl ]]; then
    install -m 0755 ./app/expressvpn/bin/expressvpnctl /usr/local/bin/expressvpnctl
  fi
  command -v expressvpnctl >/dev/null 2>&1 || {
    echo "expressvpnctl not found. Expected at /usr/local/bin/expressvpnctl"
    exit 1
  }
  [[ -x /opt/expressvpn/expressvpn.sh ]] || {
    echo "/opt/expressvpn/expressvpn.sh not found or not executable"
    exit 1
  }
}

prompt_expressvpn_inputs() {
  if [[ -z "${CODE:-}" ]]; then
    read -rsp "Enter ExpressVPN activation key: " CODE
    echo
    export CODE
  fi
  if [[ -z "${INSTANCE_COUNT:-}" ]]; then
    read -rp "How many instances do you want to run? " INSTANCE_COUNT
    export INSTANCE_COUNT
  fi
  [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "INSTANCE_COUNT must be numeric"; exit 1; }
  (( INSTANCE_COUNT > 0 )) || { echo "INSTANCE_COUNT must be > 0"; exit 1; }
}

region_for_instance() {
  local idx="$1"
  local n="${#EXPRESSVPN_REGIONS[@]}"
  local pos=$(( (idx - 1) % n ))
  echo "${EXPRESSVPN_REGIONS[$pos]}"
}

setup_ns_expressvpn_group() {
  local ns="$1"
  ip netns exec "$ns" bash -lc 'getent group expressvpn >/dev/null 2>&1 || groupadd -r expressvpn || true'
}


create_expressvpn_service_script() {
  local target="$1"
  local instance_name="$2"
  cat > "$target" <<EOF
#!/bin/sh
#
### BEGIN INIT INFO
# Provides:          expressvpn-service-${instance_name}
# Required-Start:    \$local_fs \$remote_fs
# Required-Stop:     \$local_fs \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ExpressVPN service (${instance_name})
# Description: This script starts the ExpressVPN Daemon
### END INIT INFO

[ -f /lib/lsb/init-functions ] && . /lib/lsb/init-functions

DAEMON=/opt/expressvpn/bin/expressvpn-daemon
NAME=expressvpn-service-${instance_name}
STOP_SIGNAL=INT
PIDFILE="/var/run/\$NAME.pid"
COMMON_OPTS="--quiet --pidfile \$PIDFILE"
export LD_LIBRARY_PATH=/opt/expressvpn/lib

do_start() {
    start-stop-daemon --start \$COMMON_OPTS --oknodo \
        --exec \$DAEMON --make-pidfile --background
}

do_stop() {
    start-stop-daemon --stop \$COMMON_OPTS --signal \$STOP_SIGNAL --oknodo --remove-pidfile
}

do_status() {
    start-stop-daemon --status \$COMMON_OPTS
    exit_status=\$?
    case "\$exit_status" in
    0) echo "Program '\$NAME' is running." ;;
    1) echo "Program '\$NAME' is not running and the pid file exists." ;;
    3) echo "Program '\$NAME' is not running." ;;
    4) echo "Unable to determine program '\$NAME' status." ;;
    esac
}

case "\$1" in
start) do_start ;;
stop) do_stop ;;
status) do_status ;;
*) echo "Usage: \$0 {start|stop|status}"; exit 5 ;;
esac

exit 0
EOF
  chmod 755 "$target"
}
