#!/bin/bash
# scratchpad-autohide.sh <name:type:value>...
# Hides each scratchpad when its window loses focus.
#
# type is "class" or "title" — how to identify the scratchpad window.
# Example:
#   scratchpad-autohide.sh lite-xl:class:lite-xl ghostty:title:ghostty

SCRATCHPADS=("$@")
SOCKET="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

hide_scratchpad() {
    local name="$1" type="$2" value="$3"
    hyprctl clients -j 2>/dev/null \
        | jq -r --arg type "$type" --arg value "$value" \
            '.[] | select(.[$type] == $value and (.workspace.name | startswith("special:") | not)) | .address' \
        | while read -r addr; do
            hyprctl --quiet dispatch movetoworkspacesilent "special:${name},address:${addr}"
          done
}

socat - "UNIX-CONNECT:${SOCKET}" | while IFS= read -r line; do
    [[ "$line" != "activewindow>>"* ]] && continue

    info="${line#activewindow>>}"
    active_class="${info%%,*}"
    active_title="${info#*,}"

    for spec in "${SCRATCHPADS[@]}"; do
        IFS=':' read -r name type value <<< "$spec"
        is_active=false
        case "$type" in
            class) [[ "$active_class" == "$value" ]] && is_active=true ;;
            title) [[ "$active_title" == "$value" ]] && is_active=true ;;
        esac
        [[ "$is_active" == true ]] && continue
        hide_scratchpad "$name" "$type" "$value"
    done
done
