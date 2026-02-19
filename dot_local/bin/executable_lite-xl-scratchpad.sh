#!/bin/bash
# Toggle lite-xl scratchpad. Launches into special workspace if not running.

if ! pgrep -x lite-xl > /dev/null 2>&1; then
    hyprctl dispatch exec "[workspace special:lite-xl;float;size 1400 900;center] lite-xl"
else
    hyprctl dispatch togglespecialworkspace lite-xl
fi
