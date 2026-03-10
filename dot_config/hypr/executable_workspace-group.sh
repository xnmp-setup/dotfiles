#!/usr/bin/env bash
# Workspace groups: switch all monitors together as one virtual desktop.
# Usage:
#   workspace-group.sh switch <group>   — switch all monitors to group N
#   workspace-group.sh move <group>     — move active window to group N (same monitor)
#
# Monitor layout (order matters for offset calculation):
#   slot 0 = HDMI-A-1 (top)
#   slot 1 = DP-2     (main)
#   slot 2 = DP-1     (right)

MONITORS=("HDMI-A-1" "DP-2" "DP-1")
NUM_MONITORS=${#MONITORS[@]}

action="$1"
group="$2"

if [[ -z "$action" || -z "$group" ]]; then
    echo "Usage: $0 {switch|move} <group-number>" >&2
    exit 1
fi

# Map group N + monitor slot to actual workspace number
# Group 1 → ws 1,2,3 | Group 2 → ws 4,5,6 | etc.
ws_for_slot() {
    local g="$1" slot="$2"
    echo $(( (g - 1) * NUM_MONITORS + slot + 1 ))
}

case "$action" in
    switch)
        for slot in "${!MONITORS[@]}"; do
            ws=$(ws_for_slot "$group" "$slot")
            hyprctl dispatch focusworkspaceoncurrentmonitor "$ws" &
        done
        wait
        ;;
    move)
        # Determine which monitor the active window is on
        active_monitor=$(hyprctl activewindow -j | jq -r '.monitor')
        for slot in "${!MONITORS[@]}"; do
            if [[ "${MONITORS[$slot]}" == "$active_monitor" ]]; then
                ws=$(ws_for_slot "$group" "$slot")
                hyprctl dispatch movetoworkspace "$ws"
                exit 0
            fi
        done
        echo "Active monitor '$active_monitor' not in MONITORS list" >&2
        exit 1
        ;;
    *)
        echo "Unknown action: $action" >&2
        exit 1
        ;;
esac
