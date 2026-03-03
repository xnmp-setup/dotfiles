#!/usr/bin/env bash
# hypr-session-save.sh — Save current Hyprland window state to JSON
#
# Captures class, workspace, floating state, size, position, and launch
# command (best-effort via /proc/<pid>/cmdline) for every open window.
# Writes to ~/.local/state/hypr/session.json

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
SESSION_FILE="$STATE_DIR/session.json"

mkdir -p "$STATE_DIR"

# Read all clients once
clients=$(hyprctl clients -j 2>/dev/null)
[[ -z "$clients" || "$clients" == "[]" ]] && exit 0

# Build session JSON: one entry per window
echo "$clients" | jq -c '.[]' | while IFS= read -r win; do
    class=$(echo "$win" | jq -r '.class')
    ws_id=$(echo "$win" | jq -r '.workspace.id')
    ws_name=$(echo "$win" | jq -r '.workspace.name')
    floating=$(echo "$win" | jq -r '.floating')
    pid=$(echo "$win" | jq -r '.pid')
    size=$(echo "$win" | jq -c '.size')
    at=$(echo "$win" | jq -c '.at')

    # Skip empty/unknown classes and special workspaces (scratchpads)
    [[ -z "$class" || "$class" == "null" ]] && continue
    [[ "$ws_name" == special:* ]] && continue

    # Best-effort: read launch command from /proc
    cmdline=""
    if [[ -r "/proc/$pid/cmdline" ]]; then
        # cmdline is NUL-delimited; convert to space-separated
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" | sed 's/ $//')
    fi

    jq -n --arg class "$class" \
          --argjson ws_id "$ws_id" \
          --arg ws_name "$ws_name" \
          --argjson floating "$floating" \
          --arg cmdline "$cmdline" \
          --argjson size "$size" \
          --argjson at "$at" \
          --argjson pid "$pid" \
          '{class: $class, workspace_id: $ws_id, workspace_name: $ws_name,
            floating: $floating, cmdline: $cmdline, size: $size, at: $at, pid: $pid}'
done | jq -s '.' > "$SESSION_FILE.tmp"

# Atomic write
mv "$SESSION_FILE.tmp" "$SESSION_FILE"
echo "Session saved: $(jq length "$SESSION_FILE") windows → $SESSION_FILE"
