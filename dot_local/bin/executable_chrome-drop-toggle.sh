#!/bin/bash
# Chrome scratchpad toggle. Works around Chrome's cross-profile singleton by
# detecting the new window after launch rather than using exec dispatch tracking.
#
# Parks the window in a special workspace when hidden, moves to current
# workspace as a float when shown (no overlay blocking clicks).

WORKSPACE="special:chrome-drop"
ADDR_FILE="/tmp/chrome-drop-addr"
W=1800; H=1100; Y=1440
# Center horizontally on DP-2 (starts at x=0, 3440px wide)
MON_X=0; MON_W=3440
X=$(( MON_X + (MON_W - W) / 2 ))

# Try to find the chrome-drop window by saved address
addr=""
if [[ -f "$ADDR_FILE" ]]; then
    saved=$(cat "$ADDR_FILE")
    # Verify the window still exists
    if hyprctl clients -j 2>/dev/null | jq -e --arg a "$saved" 'any(.[]; .address == $a)' > /dev/null 2>&1; then
        addr="$saved"
    fi
fi

if [[ -n "$addr" ]]; then
    ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.name')
    if [[ "$ws" == special:* ]]; then
        # Hidden — show on current workspace
        active_ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')
        hyprctl --batch "\
            dispatch movetoworkspacesilent ${active_ws},address:${addr};\
            dispatch focuswindow address:${addr};\
            dispatch resizewindowpixel exact ${W} ${H},address:${addr}"
        hyprctl dispatch movewindowpixel "exact ${X} ${Y},address:${addr}"
    else
        # Visible — park in special workspace
        hyprctl dispatch movetoworkspacesilent "${WORKSPACE},address:${addr}"
    fi
    exit 0
fi

# No chrome-drop window exists yet — create one
before=$(hyprctl clients -j 2>/dev/null | jq -c '[.[] | select(.class == "google-chrome") | .address]')
google-chrome-stable --new-window &

for _ in {1..30}; do
    sleep 0.2
    addr=$(hyprctl clients -j 2>/dev/null | jq -r \
        --argjson before "$before" \
        'first(.[] | select(.class == "google-chrome" and (.address as $a | $before | index($a) | not))) | .address // empty')
    [[ -z "$addr" ]] && continue

    echo "$addr" > "$ADDR_FILE"
    active_ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id')
    hyprctl dispatch togglefloating "address:$addr"
    sleep 0.05
    hyprctl --batch "\
        dispatch resizewindowpixel exact ${W} ${H},address:${addr};\
        dispatch movewindowpixel exact ${X} ${Y},address:${addr};\
        dispatch movetoworkspacesilent ${active_ws},address:${addr};\
        dispatch focuswindow address:${addr}"
    break
done
