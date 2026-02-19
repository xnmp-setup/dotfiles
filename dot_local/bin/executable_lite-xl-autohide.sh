#!/bin/bash
# Hide scratchpad windows (lite-xl, ghostty scratchpad) when they lose focus.

SOCKET="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

socat - "UNIX-CONNECT:${SOCKET}" | while IFS= read -r line; do
    [[ "$line" != "activewindow>>"* ]] && continue

    info="${line#activewindow>>}"
    active_class="${info%%,*}"
    active_title="${info#*,}"

    # Hide lite-xl when it loses focus
    if [[ "$active_class" != "lite-xl" ]]; then
        hyprctl clients -j 2>/dev/null \
            | jq -r '.[] | select(.class == "lite-xl" and (.workspace.name | startswith("special:") | not)) | .address' \
            | while read -r addr; do
                hyprctl --quiet dispatch movetoworkspacesilent "special:lite-xl,address:${addr}"
              done
    fi

    # Hide ghostty scratchpad when it loses focus
    if [[ "$active_title" != "scratchpad" ]]; then
        hyprctl clients -j 2>/dev/null \
            | jq -r '.[] | select(.title == "scratchpad" and (.workspace.name | startswith("special:") | not)) | .address' \
            | while read -r addr; do
                hyprctl --quiet dispatch movetoworkspacesilent "special:ghostty,address:${addr}"
              done
    fi
done
