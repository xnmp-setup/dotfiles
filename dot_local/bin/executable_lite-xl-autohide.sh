#!/bin/bash
# Hide lite-xl in a special workspace whenever it loses focus.
# Bring it back with: hyprctl dispatch togglespecialworkspace lite-xl

SOCKET="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

socat - "UNIX-CONNECT:${SOCKET}" | while IFS= read -r line; do
    [[ "$line" != "activewindow>>"* ]] && continue

    class="${line#activewindow>>}"
    class="${class%%,*}"
    [[ "$class" == "lite-xl" ]] && continue

    # Move any visible lite-xl windows to the special workspace
    hyprctl clients -j 2>/dev/null \
        | jq -r '.[] | select(.class == "lite-xl" and (.workspace.name | startswith("special:") | not)) | .address' \
        | while read -r addr; do
            hyprctl --quiet dispatch movetoworkspacesilent "special:lite-xl,address:${addr}"
          done
done
