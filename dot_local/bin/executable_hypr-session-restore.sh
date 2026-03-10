#!/usr/bin/env bash
# hypr-session-restore.sh — Restore Hyprland windows from saved session
#
# Reads ~/.local/state/hypr/session.json and relaunches windows on their
# saved workspaces. Uses a class→command mapping file for apps where
# /proc cmdline was unavailable. Skips already-running apps (dedup).

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
SESSION_FILE="$STATE_DIR/session.json"
MAP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/session-restore-map.conf"

[[ -f "$SESSION_FILE" ]] || { echo "No session file found"; exit 0; }

# Load class→command map into an associative array
declare -A CLASS_CMD
if [[ -f "$MAP_FILE" ]]; then
    while IFS='=' read -r cls cmd; do
        [[ -z "$cls" || "$cls" == \#* ]] && continue
        CLASS_CMD["$cls"]="$cmd"
    done < "$MAP_FILE"
fi

# Get currently running classes for dedup
running_classes=$(hyprctl clients -j 2>/dev/null | jq -r '.[].class' | sort -u)

# Deduplicate session entries: one launch per class
# (multiple windows of the same class are common but we only launch once)
declare -A seen_class

count=$(jq length "$SESSION_FILE")
for ((i = 0; i < count; i++)); do
    entry=$(jq -c ".[$i]" "$SESSION_FILE")

    class=$(echo "$entry" | jq -r '.class')
    ws_id=$(echo "$entry" | jq -r '.workspace_id')
    floating=$(echo "$entry" | jq -r '.floating')
    cmdline=$(echo "$entry" | jq -r '.cmdline')
    size=$(echo "$entry" | jq -c '.size')
    at=$(echo "$entry" | jq -c '.at')

    # Skip if already handled this class
    [[ -n "${seen_class[$class]}" ]] && continue
    seen_class["$class"]=1

    # Skip if already running
    if echo "$running_classes" | grep -qxF "$class"; then
        echo "Skip (running): $class"
        continue
    fi

    # Resolve launch command: saved cmdline → map file → skip
    cmd="$cmdline"
    if [[ -z "$cmd" || "$cmd" == "null" ]]; then
        cmd="${CLASS_CMD[$class]:-}"
    fi
    if [[ -z "$cmd" ]]; then
        echo "Skip (no command): $class"
        continue
    fi

    # Build window rules for hyprctl dispatch exec
    rules="workspace $ws_id silent"
    if [[ "$floating" == "true" ]]; then
        w=$(echo "$size" | jq '.[0]')
        h=$(echo "$size" | jq '.[1]')
        x=$(echo "$at" | jq '.[0]')
        y=$(echo "$at" | jq '.[1]')
        rules="$rules;float;size $w $h;move $x $y"
    fi

    echo "Restore: $class → workspace $ws_id (${floating:+float})"
    hyprctl dispatch exec "[$rules] $cmd"

    # Small delay to avoid race conditions with window rules
    sleep 0.3
done

echo "Session restore complete"
