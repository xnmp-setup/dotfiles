#!/usr/bin/env bash
# Move window within hy3 tree, falling back to cross-monitor if at edge
dir="$1"

# Capture window position before move
before=$(hyprctl activewindow -j | jq '[.at[0], .at[1], .monitor]')

# Try hy3 move
hyprctl dispatch hy3:movewindow "$dir"

# Capture after
after=$(hyprctl activewindow -j | jq '[.at[0], .at[1], .monitor]')

# If nothing changed, move across monitors
if [[ "$before" == "$after" ]]; then
    hyprctl dispatch movewindow "mon:$dir"
fi
