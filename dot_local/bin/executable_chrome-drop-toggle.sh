#!/bin/bash
# Chrome scratchpad toggle. Works around Chrome's cross-profile singleton by
# detecting the new window after launch rather than using exec dispatch tracking.

WORKSPACE="special:chrome-drop"
W=1800; H=1100; Y=1440
# Center horizontally on DP-2 (starts at x=0, 3440px wide)
MON_X=0; MON_W=3440
X=$(( MON_X + (MON_W - W) / 2 ))

# Already set up — just toggle visibility
if hyprctl clients -j 2>/dev/null | jq -e --arg ws "$WORKSPACE" 'any(.[]; .workspace.name == $ws)' > /dev/null; then
    hyprctl dispatch togglespecialworkspace chrome-drop
    exit 0
fi

# Snapshot existing Chrome windows
before=$(hyprctl clients -j 2>/dev/null | jq -c '[.[] | select(.class == "google-chrome") | .address]')

# Open a new Chrome window via the existing process (uses your normal profile)
google-chrome-stable --new-window &

# Poll for the new window, then float/size/position/move to special workspace
for _ in {1..30}; do
    sleep 0.2
    addr=$(hyprctl clients -j 2>/dev/null | jq -r \
        --argjson before "$before" \
        '[.[] | select(.class == "google-chrome" and (.address as $a | $before | index($a) | not))] | first | .address // empty')
    [[ -z "$addr" ]] && continue

    hyprctl dispatch togglefloating "address:$addr"
    sleep 0.05
    hyprctl dispatch resizewindowpixel "exact ${W} ${H},address:$addr"
    hyprctl dispatch movewindowpixel "exact ${X} ${Y},address:$addr"
    hyprctl dispatch movetoworkspacesilent "${WORKSPACE},address:$addr"
    hyprctl dispatch togglespecialworkspace chrome-drop
    break
done
