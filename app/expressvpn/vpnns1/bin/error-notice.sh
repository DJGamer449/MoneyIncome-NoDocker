#!/bin/bash

# Overwrite PATH with known safe defaults
PATH="/usr/bin:/usr/sbin:/bin:/sbin"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

readonly appName="ExpressVPN"
readonly brandCode="expressvpn"
readonly brandPrefixVpn="expressvpn"
readonly installDir="/opt/${brandPrefixVpn}"

readonly title="${appName} Error"
readonly str_safeMode="Restart in Safe Mode"
readonly str_ok="Ok"
readonly str_support="Contact Support"
readonly str_message_1="${appName} was not able to initialize OpenGL."
readonly str_message_2="If you have hardware 3D acceleration, please check your video drivers."
readonly str_message_3="You can try restarting in safe mode to use software rendering."
readonly str_text="${str_message_1}\n\n${str_message_2}\n\n${str_message_3}"

function do_restart_safe () {
    "${installDir}/bin/${brandCode}-client" --safe-mode &
}

function do_support () {
    if hash xdg-open 2>/dev/null; then
        xdg-open "https://www.ujsrxts.com/support/"
    fi
}

if hash zenity 2>/dev/null; then
    answer=$(zenity --title="${title}" \
        --warning \
        --no-wrap \
        --extra-button="${str_safeMode}" \
        --extra-button="${str_support}" \
        --text="${str_text}")

    if [ "$answer" == "$str_safeMode" ]; then
        do_restart_safe
    elif [ "$answer" == "$str_support" ]; then
        do_support
    fi

elif hash kdialog 2>/dev/null; then
    answer=$(kdialog --radiolist "${str_text}" \
        ignore "Close ${appName}" on \
        restart "${str_safeMode}" off \
        support "${str_support}" off)

    if [ "$answer" == "restart" ]; then
        do_restart_safe
    elif [ "$answer" == "support" ]; then
        do_support
    fi
fi
