#!/bin/bash
# scratchpad-autohide.sh <name:type:value>...
# Hides each scratchpad when its window loses focus.
#
# type is "class", "title", or "addr-file" — how to identify the scratchpad window.
# addr-file reads a window address from the given file path.
#
# Examples:
#   scratchpad-autohide.sh lite-xl:class:com.lite_xl.LiteXL ghostty-drop:title:ghostty-drop
#   scratchpad-autohide.sh chrome-drop:addr-file:/tmp/chrome-drop-addr

SCRATCHPADS=("$@")
SOCKET="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

hide_scratchpad() {
    local name="$1" type="$2" value="$3"
    if [[ "$type" == "addr-file" ]]; then
        [[ -f "$value" ]] || return
        local addr
        addr=$(cat "$value")
        [[ -z "$addr" ]] && return
        # Only hide if it's on a regular workspace
        local ws
        ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" \
            '.[] | select(.address == $a) | .workspace.name // empty')
        if [[ -n "$ws" && "$ws" != special:* ]]; then
            hyprctl --quiet dispatch movetoworkspacesilent "special:${name},address:${addr}"
        fi
    else
        hyprctl clients -j 2>/dev/null \
            | jq -r --arg type "$type" --arg value "$value" \
                '.[] | select(.[$type] == $value and (.workspace.name | startswith("special:") | not)) | .address' \
            | while read -r addr; do
                hyprctl --quiet dispatch movetoworkspacesilent "special:${name},address:${addr}"
              done
    fi
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
            addr-file)
                if [[ -f "$value" ]]; then
                    local_addr=$(cat "$value")
                    cur=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$local_addr" \
                        '.[] | select(.address == $a) | .class // empty')
                    [[ "$active_class" == "$cur" ]] && {
                        # Active window has same class — check if it's the exact window
                        active_addr=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address')
                        [[ "$active_addr" == "$local_addr" ]] && is_active=true
                    }
                fi
                ;;
        esac
        [[ "$is_active" == true ]] && continue
        hide_scratchpad "$name" "$type" "$value"
    done
done
