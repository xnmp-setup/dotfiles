#!/bin/bash
# toggle-scratchpad.sh <name> <w> <h> [--class <class>] [<x> <y>] <cmd...>
#
# If --class is given, matches windows by that class instead of <name>.
# If x y are given, positions the window at those absolute coords after launch.
# Otherwise, centers on the current monitor.
#
# Examples:
#   toggle-scratchpad.sh lite-xl 1400 900 lite-xl
#   toggle-scratchpad.sh ghostty-drop 1600 1000 920 1440 ghostty --title=ghostty-drop
#   toggle-scratchpad.sh ytmusic 1400 900 --class "YouTube Music Desktop App" youtube-music-desktop-app

NAME="$1"; W="$2"; H="$3"; shift 3

MATCH=""
if [[ "$1" == --class ]]; then
    MATCH="$2"; shift 2
fi

TARGET_X=""; TARGET_Y=""
if [[ "$1" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
    TARGET_X="$1"; TARGET_Y="$2"; shift 2
fi
CMD="$*"

MATCH="${MATCH:-$NAME}"
exists=$(hyprctl clients -j 2>/dev/null | jq --arg n "$MATCH" \
    -e 'any(.[]; .class == $n or .title == $n or .workspace.name == ("special:" + $n))')

if [[ "$exists" != "true" ]]; then
    if [[ -n "$TARGET_X" ]]; then
        hyprctl dispatch exec "[workspace special:${NAME};float;size ${W} ${H}] ${CMD}"
        # Poll until window appears, then move it into position
        (
            for _ in {1..20}; do
                sleep 0.15
                addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg n "$MATCH" \
                    '.[] | select(.class == $n or .title == $n) | .address' | head -1)
                if [[ -n "$addr" ]]; then
                    hyprctl dispatch movewindowpixel "exact ${TARGET_X} ${TARGET_Y},address:${addr}"
                    break
                fi
            done
        ) &
    else
        hyprctl dispatch exec "[workspace special:${NAME};float;size ${W} ${H};center] ${CMD}"
    fi
else
    hyprctl dispatch togglespecialworkspace "${NAME}"
fi
