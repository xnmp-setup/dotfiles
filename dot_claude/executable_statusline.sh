#!/bin/bash
input=$(cat)

DIR=$(echo "$input" | jq -r '.workspace.current_dir')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[2m'; RESET='\033[0m'

# Git branch (cached)
CACHE_DIR="$DIR"
CACHE_KEY="/tmp/statusline-git-$(echo "$CACHE_DIR" | md5sum | cut -d' ' -f1)"
if [ ! -f "$CACHE_KEY" ] || [ $(($(date +%s) - $(stat -c %Y "$CACHE_KEY" 2>/dev/null || echo 0))) -gt 5 ]; then
    git -C "$CACHE_DIR" branch --show-current 2>/dev/null > "$CACHE_KEY" || echo "" > "$CACHE_KEY"
fi
BRANCH=$(tr -d '\n' < "$CACHE_KEY")

# Progress bar (ASCII safe)
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

BAR_WIDTH=15
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=$(printf "%${FILLED}s" | tr ' ' '#')$(printf "%${EMPTY}s" | tr ' ' '-')

OUT="${CYAN}${DIR##*/}${RESET}"
[ -n "$BRANCH" ] && OUT="${OUT} ${DIM}on${RESET} ${GREEN}${BRANCH}${RESET}"
OUT="${OUT} ${BAR_COLOR}[${BAR}]${RESET} ${PCT}%"

echo -e "$OUT"
