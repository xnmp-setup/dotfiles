#!/bin/bash
# toggle-scratchpad.sh <name> <w> <h> [options...] [<x> <y>] <cmd...>
#
# Toggles a scratchpad window by parking it in a special workspace when hidden
# and moving it to the current workspace as a float when shown.
#
# Options:
#   --class <class>   Match windows by this class (default: <name>)
#   --singleton       Use snapshot detection for apps that reuse an existing
#                     process (e.g. Chrome)
#
# If x y are given (two consecutive integers), positions the window there.
# Otherwise, centers on the current monitor.
#
# Window addresses are saved to /tmp/scratchpad-<name>.addr for autohide.
#
# Examples:
#   toggle-scratchpad.sh lite-xl 1400 900 --class com.lite_xl.LiteXL lite-xl
#   toggle-scratchpad.sh ghostty-drop 1600 1000 920 1440 ghostty --title=ghostty-drop
#   toggle-scratchpad.sh chrome-drop 1800 1100 --class google-chrome --singleton google-chrome-stable --new-window

NAME="$1"; W="$2"; H="$3"; shift 3

MATCH=""; SINGLETON=false
while [[ "$1" == --* ]]; do
    case "$1" in
        --class)    MATCH="$2"; shift 2 ;;
        --singleton) SINGLETON=true; shift ;;
        *) break ;;
    esac
done

TARGET_X=""; TARGET_Y=""
if [[ "$1" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
    TARGET_X="$1"; TARGET_Y="$2"; shift 2
fi
CMD="$*"
MATCH="${MATCH:-$NAME}"
ADDR_FILE="/tmp/scratchpad-${NAME}.addr"

# --- Helpers ---

dim_on()  { hyprctl --quiet keyword decoration:dim_inactive true; }
dim_off() { hyprctl --quiet keyword decoration:dim_inactive false; }

show_window() {
    local addr="$1"
    local active_ws
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
    dim_on
}

hide_window() {
    local addr="$1"
    hyprctl dispatch movetoworkspacesilent "special:${NAME},address:${addr}"
    dim_off
}

save_addr() { echo "$1" > "$ADDR_FILE"; }

# --- Find existing window ---

addr=""
if [[ -f "$ADDR_FILE" ]]; then
    saved=$(cat "$ADDR_FILE")
    if hyprctl clients -j 2>/dev/null | jq -e --arg a "$saved" 'any(.[]; .address == $a)' > /dev/null 2>&1; then
        addr="$saved"
    fi
fi

# --- Toggle ---

if [[ -n "$addr" ]]; then
    ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.name')
    if [[ "$ws" == special:* ]]; then
        show_window "$addr"
    else
        hide_window "$addr"
    fi
    exit 0
fi

# --- Launch new window ---

if [[ "$SINGLETON" == true ]]; then
    # Snapshot existing windows, launch, poll for the new one
    before=$(hyprctl clients -j 2>/dev/null | jq -c --arg c "$MATCH" \
        '[.[] | select(.class == $c) | .address]')
    $CMD &
    for _ in {1..30}; do
        sleep 0.2
        addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$MATCH" --argjson before "$before" \
            'first(.[] | select(.class == $c and (.address as $a | $before | index($a) | not))) | .address // empty')
        [[ -n "$addr" ]] && break
    done
    [[ -z "$addr" ]] && exit 1
    save_addr "$addr"
    hyprctl dispatch togglefloating "address:$addr"
    sleep 0.05
    show_window "$addr"
else
    dim_on
    if [[ -n "$TARGET_X" ]]; then
        hyprctl dispatch exec "[float;size ${W} ${H}] ${CMD}"
    else
        hyprctl dispatch exec "[float;size ${W} ${H};center] ${CMD}"
    fi
    # Poll for the new window and save its address
    (
        for _ in {1..20}; do
            sleep 0.15
            addr=$(hyprctl clients -j 2>/dev/null | jq -r --arg n "$MATCH" \
                'first(.[] | select(.class == $n or .title == $n)) | .address // empty')
            if [[ -n "$addr" ]]; then
                save_addr "$addr"
                [[ -n "$TARGET_X" ]] && hyprctl dispatch movewindowpixel "exact ${TARGET_X} ${TARGET_Y},address:${addr}"
                break
            fi
        done
    ) &
fi
