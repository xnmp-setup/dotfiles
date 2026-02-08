#!/bin/bash

# Check if active window is already a terminal
ACTIVE_CLASS=$(hyprctl activewindow -j | jq -r '.class')

if [ "$ACTIVE_CLASS" = "com.mitchellh.ghostty" ]; then
    exit 0
fi

# Get monitor name from active workspace
FOCUSED_MON_NAME=$(hyprctl activeworkspace -j | jq -r '.monitor')

# Get the monitor ID from the monitor name
FOCUSED_MON_ID=$(hyprctl monitors -j | jq -r ".[] | select(.name == \"$FOCUSED_MON_NAME\") | .id")

GHOSTTY_ADDR=$(hyprctl clients -j | jq -r ".[] | select(.class == \"com.mitchellh.ghostty\" and .monitor == $FOCUSED_MON_ID) | .address" | head -1)

if [ -n "$GHOSTTY_ADDR" ]; then
    hyprctl dispatch focuswindow address:$GHOSTTY_ADDR
else
    ghostty &
fi
