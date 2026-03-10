#!/bin/bash
input=$(cat)

DIR=$(echo "$input" | jq -r '.workspace.current_dir')

# --- Context % (cache last non-null to avoid jumping to 0% while thinking) ---
PCT_CACHE_KEY="/tmp/statusline-pct-$(echo "$DIR" | md5 -q 2>/dev/null || echo "$DIR" | md5sum | cut -d' ' -f1)"

SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')
RAW_PCT=$(echo "$input" | jq -r '.context_window.used_percentage')

if [ "$RAW_PCT" != "null" ] && [ -n "$RAW_PCT" ] && [ "$RAW_PCT" != "0" ] && [ "$RAW_PCT" != "0.0" ]; then
  PCT=$(printf "%.0f" "$RAW_PCT" 2>/dev/null || echo "$RAW_PCT" | cut -d. -f1)
  echo "$SESSION_ID:$PCT" > "$PCT_CACHE_KEY"
else
  if [ -f "$PCT_CACHE_KEY" ]; then
    CACHE_CONTENT=$(cat "$PCT_CACHE_KEY")
    CACHE_SESSION=$(echo "$CACHE_CONTENT" | cut -d: -f1)
    CACHE_PCT=$(echo "$CACHE_CONTENT" | cut -d: -f2)
    # Only use cache if session ID matches
    if [ "$CACHE_SESSION" = "$SESSION_ID" ] && [ -n "$SESSION_ID" ]; then
      PCT=$CACHE_PCT
    else
      PCT=0
    fi
  else
    PCT=0
  fi
fi
# ---------------------------------------------------------------------------

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[2m'; RESET='\033[0m'

# Git branch (cached)
CACHE_DIR="$DIR"
CACHE_KEY="/tmp/statusline-git-$(echo "$CACHE_DIR" | md5 -q 2>/dev/null || echo "$CACHE_DIR" | md5sum | cut -d' ' -f1)"
if [ ! -f "$CACHE_KEY" ] || [ $(($(date +%s) - $(stat -f %m "$CACHE_KEY" 2>/dev/null || stat -c %Y "$CACHE_KEY" 2>/dev/null || echo 0))) -gt 5 ]; then
    git -C "$CACHE_DIR" branch --show-current 2>/dev/null > "$CACHE_KEY" || echo "" > "$CACHE_KEY"
fi
BRANCH=$(tr -d '\n' < "$CACHE_KEY")

# Get git root directory name
GIT_ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$GIT_ROOT" ]; then
  DISPLAY_DIR="${GIT_ROOT##*/}"
else
  DISPLAY_DIR="${DIR##*/}"
fi

# Progress bar (ASCII safe)
if [ "$PCT" -ge 75 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 50 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

BAR_WIDTH=15
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=$(printf "%${FILLED}s" | tr ' ' '#')$(printf "%${EMPTY}s" | tr ' ' '-')

OUT="${CYAN}${DISPLAY_DIR}${RESET}"
[ -n "$BRANCH" ] && OUT="${OUT} ${DIM}on${RESET} ${GREEN}${BRANCH}${RESET}"
OUT="${OUT} ${BAR_COLOR}[${BAR}]${RESET} ${PCT}%"

echo -e "$OUT"