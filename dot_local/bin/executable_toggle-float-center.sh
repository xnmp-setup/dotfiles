#!/bin/bash
# Toggle floating and position at top-center: 50% width, 80% height.

addr=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address')
floating=$(hyprctl activewindow -j 2>/dev/null | jq -r '.floating')

hyprctl dispatch togglefloating

if [[ "$floating" == "false" ]]; then
    # Was tiled, now floating — resize and position
    mon=$(hyprctl monitors -j 2>/dev/null | jq -c 'first(.[] | select(.focused))')
    mon_x=$(echo "$mon" | jq -r '.x')
    mon_y=$(echo "$mon" | jq -r '.y')
    mon_w=$(echo "$mon" | jq -r '.width')
    mon_h=$(echo "$mon" | jq -r '.height')
    scale=$(echo "$mon" | jq -r '.scale')

    w=$(echo "$mon_w $scale" | awk '{printf "%d", $1 / $2 * 0.5}')
    h=$(echo "$mon_h $scale" | awk '{printf "%d", $1 / $2 * 0.8}')
    x=$(echo "$mon_x $mon_w $scale $w" | awk '{printf "%d", $1 + ($2 / $3 - $4) / 2}')
    y=$mon_y

    hyprctl --batch "\
        dispatch resizewindowpixel exact ${w} ${h},address:${addr};\
        dispatch movewindowpixel exact ${x} ${y},address:${addr}"
fi
