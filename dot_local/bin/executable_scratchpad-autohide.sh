#!/bin/bash
# scratchpad-autohide.sh <name>...
# Hides each scratchpad when its window loses focus.
#
# Reads window addresses from /tmp/scratchpad-<name>.addr (written by
# toggle-scratchpad.sh). On focus change, any scratchpad whose window
# is visible on a regular workspace and is not the active window gets
# parked back in its special workspace.
#
# Example:
#   scratchpad-autohide.sh lite-xl ghostty-drop ytmusic chrome-drop

NAMES=("$@")
SOCKET="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

hide_if_visible() {
    local name="$1" addr_file="/tmp/scratchpad-${name}.addr"
    [[ -f "$addr_file" ]] || return
    local addr
    addr=$(cat "$addr_file")
    [[ -z "$addr" ]] && return

    local ws
    ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" \
        '(.[] | select(.address == $a) | .workspace.name) // empty')
    if [[ -n "$ws" && "$ws" != special:* ]]; then
        hyprctl --quiet dispatch movetoworkspacesilent "special:${name},address:${addr}"
        hyprctl --quiet keyword decoration:dim_inactive false
    fi
}

socat - "UNIX-CONNECT:${SOCKET}" | while IFS= read -r line; do
    [[ "$line" != "activewindow>>"* ]] && continue

    # Get the active window's address
    active_addr=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')

    for name in "${NAMES[@]}"; do
        addr_file="/tmp/scratchpad-${name}.addr"
        [[ -f "$addr_file" ]] || continue
        saved=$(cat "$addr_file")
        # If the active window IS this scratchpad, skip hiding it
        [[ "$active_addr" == "$saved" ]] && continue
        hide_if_visible "$name"
    done
done
