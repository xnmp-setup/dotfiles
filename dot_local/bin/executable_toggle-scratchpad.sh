#!/bin/bash
# toggle-scratchpad.sh <name> <w> <h> <cmd...>
# Position is controlled via windowrule in hyprland.conf.
#
# Examples:
#   toggle-scratchpad.sh lite-xl 1400 900 lite-xl
#   toggle-scratchpad.sh ghostty-drop 2800 550 ghostty --title=ghostty-drop

NAME="$1"; W="$2"; H="$3"; shift 3
CMD="$*"

exists=$(hyprctl clients -j 2>/dev/null | jq --arg n "$NAME" \
    -e 'any(.[]; .class == $n or .title == $n or .workspace.name == ("special:" + $n))')

if [[ "$exists" != "true" ]]; then
    hyprctl dispatch exec "[workspace special:${NAME};float;size ${W} ${H}] ${CMD}"
else
    hyprctl dispatch togglespecialworkspace "${NAME}"
fi
