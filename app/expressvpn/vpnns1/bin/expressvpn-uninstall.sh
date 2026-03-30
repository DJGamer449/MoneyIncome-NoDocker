#!/bin/bash

# Overwrite PATH with known safe defaults
PATH="/usr/bin:/usr/sbin:/bin:/sbin"

logFile="/dev/null"

# Check if running with sudo (not allowed)
if [ -n "$SUDO_USER" ]; then
    echo "Error: Do not run this script with sudo."
    echo "Run as your regular user (the script will prompt for sudo when needed),"
    echo "or run as root directly if on a headless system."
    exit 1
fi

# Determine if running as actual root
RUNNING_AS_ROOT=false
if [ "$EUID" -eq 0 ]; then
    RUNNING_AS_ROOT=true
fi

# Helper function to conditionally use sudo
function _sudo() {
    if [ "$RUNNING_AS_ROOT" = true ]; then
        "$@"
    else
        sudo "$@"
    fi
}

readonly appName="ExpressVPN"
readonly brandPrefix="expressvpn"
readonly brandPrefixVpn="expressvpn"
readonly linuxAppName="expressvpn"
readonly installDir="/opt/${brandPrefixVpn}"
readonly serviceName="${brandPrefixVpn}"
readonly groupName="${brandPrefixVpn}"
readonly hnsdGroupName="${brandPrefix}hnsd"         # The group used by the Handshake DNS service
readonly routingTableName="{{BRAND_ANCHOR}}rt"
readonly vpnOnlyroutingTableName="{{BRAND_ANCHOR}}Onlyrt"
readonly wireguardRoutingTableName="{{BRAND_ANCHOR}}Wgrt"
readonly forwardedRoutingTableName="{{BRAND_ANCHOR}}Fwdrt" # For forwarded packets
readonly ctlExecutableName="expressvpnctl"
readonly ctlExecutablePath="${installDir}/bin/${ctlExecutableName}"
readonly wgIfPrefix="wg${brandPrefix}"
readonly ctlSymlinkPath="/usr/local/bin/${ctlExecutableName}"
readonly nmConfigDir="/etc/NetworkManager/conf.d"
readonly nmConfigPath="${nmConfigDir}/${wgIfPrefix}.conf" # Our custom NetworkManager config
readonly browserHelperManifest="com.expressvpn.helper.json"
readonly browserHelperManifestChromePath="$HOME/.config/google-chrome/NativeMessagingHosts/${browserHelperManifest}"
readonly browserHelperManifestChromiumPath="$HOME/.config/chromium/NativeMessagingHosts/${browserHelperManifest}"
readonly browserHelperManifestFirefoxPath="$HOME/.mozilla/native-messaging-hosts/${browserHelperManifest}"

function enableLogging() {
    logFile="/tmp/vpn_install.log"
    [ -f $logFile ] && rm $logFile
}
function echoPass() {
    printf '\e[92m\xE2\x9C\x94\e[0m %s\n' "$@"
    echo "$(date +"[%Y-%m-%d %H:%M:%S]") [ OK ] $@" >> "$logFile" || true
}
function echoFail() {
    printf '\e[91m\xE2\x9C\x98\e[0m %s\n' "$@"
    echo "$(date +"[%Y-%m-%d %H:%M:%S]") [FAIL] $@" >> "$logFile" || true
}
function fail() {
    echoFail "$@"
    exit 1
}

function uninstall_browser_manifest() {
    local manifestPath="$1"
    if [ -f "${manifestPath}" ]; then
        if rm "${manifestPath}"; then
            echoPass "Uninstalled browser manifest: ${manifestPath}"
        else
            echoFail "Failed to uninstall browser manifest: ${manifestPath}"
        fi
    fi
}

function uninstall_all_browser_manifests() {
    uninstall_browser_manifest "${browserHelperManifestChromePath}"
    uninstall_browser_manifest "${browserHelperManifestChromiumPath}"
    uninstall_browser_manifest "${browserHelperManifestFirefoxPath}"
}

confirm() {
    read -r -p "${1:-Proceed with uninstall? [y/N]} " response
    case "$response" in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            exit 1
            ;;
    esac
}

function disableDaemon() {
    local systemdServiceLocation="/etc/systemd/system/${serviceName}.service"
    local sysvinitServiceLocation="/etc/init.d/${serviceName}"
    local openrcServiceLocation="/etc/init.d/${serviceName}"

    if [ -f $systemdServiceLocation ]; then
        _sudo systemctl stop $serviceName
        echoPass "Stopped daemon"
        _sudo systemctl disable $serviceName
        echoPass "Disabled daemon"
        sleep 1
        _sudo rm $systemdServiceLocation
    # openrcServiceLocation is set to the same file as sysvinitServiceLocation so we need the extra rc-status check
    # to distinguish it from a sysvinit system
    elif rc-status > /dev/null 2>&1 && [ -f "$openrcServiceLocation" ]; then
        _sudo rc-service $serviceName stop
        echoPass "Stopped daemon"
        _sudo rc-update del $serviceName
        echoPass "Disabled daemon"
        sleep 1
        _sudo rm $openrcServiceLocation
    elif [ -f $sysvinitServiceLocation ]; then
        _sudo service $serviceName stop
        echoPass "Stopped daemon"
        _sudo update-rc.d $serviceName remove
        echoPass "Disabled daemon"
        sleep 1
        _sudo rm $sysvinitServiceLocation
     fi
}

function removeGroups() {
    for group in "$@"; do
        if grep -q $group /etc/group; then
            _sudo groupdel $group || true
        fi
    done
    true
}

function removeRoutingTable() {
    local routesLocation=/etc/iproute2/rt_tables
    local routingTable="$1"

    if [[ -f $routesLocation ]] && grep -q "$routingTable" $routesLocation; then
        grep -v "$routingTable" $routesLocation | _sudo tee $routesLocation > /dev/null
        echoPass "Removed $routingTable routing table"
    fi

    true
}

function removeWireguardUnmanaged() {
    [ -f "$nmConfigPath" ] && _sudo rm -f "$nmConfigPath"
}

function removeCgroupMount() {
    local cgroupPath="${installDir}/etc/cgroup/net_cls"
    if [ -d "$cgroupPath" ] && mountpoint -q "$cgroupPath" 2>/dev/null; then
        sudo umount "$cgroupPath" 2>/dev/null || true
        echoPass "Unmounted cgroup filesystem"
    fi
}

if [[ "$1" == "startuninstall" ]] ; then
    echo "==================================="
    echo "$appName Uninstaller"
    echo "==================================="
    echo ""

    if [ "$RUNNING_AS_ROOT" = true ]; then
        echo "WARNING: Running as root."
        echo "Root's user settings will be removed, but other users' settings"
        echo "(in ~/.config/${linuxAppName}/) will not be removed automatically."
        echo ""
    fi

    confirm

    # Stop client - skip if running as root (don't know which user's client to stop)
    if [ "$RUNNING_AS_ROOT" = false ]; then
        killall "${brandPrefix}-client" 2>/dev/null || true
        echoPass "Stopped existing client"
    fi

    sleep 1
    disableDaemon
    _sudo rm -f "/usr/share/applications/${brandPrefixVpn}.desktop"

    # Remove the ctl symlink, as long as it points to the correct ctl
    # (this is very paranoid since it's in /usr/local/bin)
    existingSymlinkTarget=$(readlink "${ctlSymlinkPath}" || true)
    if [ "${existingSymlinkTarget}" = "${ctlExecutablePath}" ]; then
        _sudo rm "${ctlSymlinkPath}"
    fi


    # User-specific cleanup
    # Always clean up current user's files (including root if running as root)
    [ -f "$HOME/.config/autostart/${brandPrefixVpn}.desktop" ] && rm "$HOME/.config/autostart/${brandPrefixVpn}.desktop"
    [ -e "$HOME/.config/${linuxAppName}" ] && rm -rf "$HOME/.config/${linuxAppName}/"
    uninstall_all_browser_manifests

    # If running as root, remind that other users' settings are not removed
    if [ "$RUNNING_AS_ROOT" = true ]; then
        echo ""
        echo "Note: If other users installed the client, their settings in"
        echo "      ~/.config/${linuxAppName}/ will remain and must be removed manually."
    fi

    [ -f "/usr/share/pixmaps/${brandPrefixVpn}.png" ] && _sudo rm -f "/usr/share/pixmaps/${brandPrefixVpn}.png"
    [ -f "/etc/apport/blacklist.d/${brandPrefixVpn}" ] && _sudo rm -f "/etc/apport/blacklist.d/${brandPrefixVpn}"
    removeCgroupMount

    echoPass "Removed $appName System files"
    _sudo rm -rf "/opt/${brandPrefixVpn}/"
    removeGroups $groupName $hnsdGroupName
    removeRoutingTable $routingTableName
    removeRoutingTable $vpnOnlyroutingTableName
    removeRoutingTable $wireguardRoutingTableName
    removeRoutingTable $forwardedRoutingTableName
    removeWireguardUnmanaged
    echoPass "Uninstall finished"
    read -n 1 -s -r -p "Press any key to continue"
else
    # Try to generate a temporary file for writing the uninstaller. Otherwise
    # Fall back onto a hard-coded path.
    UNINSTALL_SCRIPT="/tmp/$brandPrefix-uninstall.sh"

    if hash mktemp 2>/dev/null; then
        UNINSTALL_SCRIPT=$(mktemp)
    fi

    [[ -f "$UNINSTALL_SCRIPT" ]] && rm "$UNINSTALL_SCRIPT"
    cp -f $0 "$UNINSTALL_SCRIPT"
    chmod +x "$UNINSTALL_SCRIPT"

    $UNINSTALL_SCRIPT startuninstall
fi
