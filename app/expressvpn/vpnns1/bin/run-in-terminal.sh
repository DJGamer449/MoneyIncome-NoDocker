#! /bin/bash

# Ensure $1 is an absolute path to an executable/script
if [[ "$1" != /* ]] || [ ! -x "$1" ]; then
    echo "Error: Provide an absolute path to an executable."
    exit 2
fi

TERMCMD=""
FLAGS=""

# Since we never had any issue with konsole, if it's installed
# it's our first choice.
if [ -x /usr/bin/konsole ]; then
    TERMCMD="/usr/bin/konsole"
    FLAGS="-e"
# xterm is our second safest choice, on a non-KDE systems.
elif [ -x /usr/bin/xterm ]; then
    TERMCMD="/usr/bin/xterm"
    FLAGS="-e"
elif [ -x /usr/bin/xfce4-terminal ]; then
    TERMCMD="/usr/bin/xfce4-terminal"
    FLAGS="--command"
elif [ -x /usr/bin/kgx ]; then
    TERMCMD="/usr/bin/kgx"
    FLAGS="-- bash -c"
elif [ -x /usr/bin/alacritty ]; then
    TERMCMD="/usr/bin/alacritty"
    FLAGS="-e"
elif [ -x /usr/bin/kitty ]; then
    TERMCMD="/usr/bin/kitty"
    FLAGS=""
# Keeping these two as last ones since they proved to be flaky.
# gnome-terminal can potentially break the whole DE on Ubuntu 20 and 22 systems.
elif [ -x /usr/bin/ptyxis ]; then
    TERMCMD="/usr/bin/ptyxis"
    FLAGS="-- bash -c"
elif [ -x /usr/bin/gnome-terminal ]; then
    TERMCMD="/usr/bin/gnome-terminal"
    FLAGS="-- bash -c"

else
    exit 3
fi

echo "Using terminal app $TERMCMD $FLAGS $1"
# Start the terminal with the specified command
# shellcheck disable=SC2086  # Word splitting on $FLAGS is intentional
nohup $TERMCMD $FLAGS "$1" >/dev/null 2>&1 &
