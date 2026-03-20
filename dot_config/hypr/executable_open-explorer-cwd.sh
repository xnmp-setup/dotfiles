#!/usr/bin/env bash
# Open tauri-explorer at the CWD of the focused terminal's shell process.
# Falls back to $HOME if the focused window isn't a terminal.

active_json=$(hyprctl activewindow -j)
class=$(echo "$active_json" | jq -r '.class')
pid=$(echo "$active_json" | jq -r '.pid')

# Only extract CWD from known terminal classes
case "$class" in
    com.mitchellh.ghostty|foot|Alacritty|kitty|org.wezfurlong.wezterm)
        # Find the deepest foreground shell child (skip intermediate processes)
        shell_pid=$(pgrep -P "$pid" -a 2>/dev/null | grep -E '(bash|zsh|fish|sh)' | head -1 | awk '{print $1}')
        if [[ -n "$shell_pid" ]]; then
            cwd=$(readlink "/proc/$shell_pid/cwd" 2>/dev/null)
        fi
        ;;
esac

cd "${cwd:-$HOME}" && exec tauri-explorer
