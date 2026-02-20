#!/bin/bash
# toggle-scratchpad.sh <name> <w> <h> [--class <class>] [<x> <y>] <cmd...>
#
# Shows/hides a scratchpad window by moving it between a parking special
# workspace and the current regular workspace. This avoids the special
# workspace overlay, so clicking outside the window works normally.
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

# Find the scratchpad window
window=$(hyprctl clients -j 2>/dev/null | jq -c --arg n "$MATCH" \
    'first(.[] | select(.class == $n or .title == $n)) // empty')

if [[ -z "$window" ]]; then
    # Window doesn't exist — launch it on current workspace as a float
    if [[ -n "$TARGET_X" ]]; then
        hyprctl dispatch exec "[float;size ${W} ${H}] ${CMD}"
        (
            for _ in {1..20}; do
                sleep 0.15
                addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg n "$MATCH" \
                    'first(.[] | select(.class == $n or .title == $n)) | .address // empty')
                if [[ -n "$addr" ]]; then
                    hyprctl dispatch movewindowpixel "exact ${TARGET_X} ${TARGET_Y},address:${addr}"
                    break
                fi
            done
        ) &
    else
        hyprctl dispatch exec "[float;size ${W} ${H};center] ${CMD}"
    fi
    exit 0
fi

addr=$(echo "$window" | jq -r '.address')
ws=$(echo "$window" | jq -r '.workspace.name')

if [[ "$ws" == special:* ]]; then
    # Hidden — move to current workspace and focus
    active_ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')
    hyprctl --batch "\
        dispatch movetoworkspacesilent ${active_ws},address:${addr};\
        dispatch focuswindow address:${addr};\
        dispatch resizewindowpixel exact ${W} ${H},address:${addr}"
    if [[ -n "$TARGET_X" ]]; then
        hyprctl dispatch movewindowpixel "exact ${TARGET_X} ${TARGET_Y},address:${addr}"
    else
        hyprctl dispatch centerwindow
    fi
else
    # Visible — park in special workspace
    hyprctl dispatch movetoworkspacesilent "special:${NAME},address:${addr}"
fi
