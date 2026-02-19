#!/bin/bash
# toggle-scratchpad.sh <name> <w> <h> [<x> <y>] <cmd...>
#
# If x y are given, positions the window at those absolute coords after launch.
# Otherwise, centers on the current monitor.
#
# Examples:
#   toggle-scratchpad.sh lite-xl 1400 900 lite-xl
#   toggle-scratchpad.sh ghostty-drop 1200 1000 1120 1440 ghostty --title=ghostty-drop

NAME="$1"; W="$2"; H="$3"; shift 3

TARGET_X=""; TARGET_Y=""
if [[ "$1" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
    TARGET_X="$1"; TARGET_Y="$2"; shift 2
fi
CMD="$*"

exists=$(hyprctl clients -j 2>/dev/null | jq --arg n "$NAME" \
    -e 'any(.[]; .class == $n or .title == $n or .workspace.name == ("special:" + $n))')

if [[ "$exists" != "true" ]]; then
    if [[ -n "$TARGET_X" ]]; then
        hyprctl dispatch exec "[workspace special:${NAME};float;size ${W} ${H}] ${CMD}"
        # Poll until window appears, then move it into position
        (
            for _ in {1..20}; do
                sleep 0.15
                addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg n "$NAME" \
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
