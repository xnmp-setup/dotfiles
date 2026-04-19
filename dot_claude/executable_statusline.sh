#!/usr/bin/env bash
# Wrapper around ccstatusline that recolors the context bar based on usage %.
# ccstatusline reads JSON from stdin, so we tee stdin to it.

OUTPUT=$(cat | bunx -y ccstatusline@latest 2>/dev/null)

# Extract the percentage from the context bar, e.g. "(15%)"
PCT=$(echo "$OUTPUT" | grep -oE '\([0-9]+%\)' | head -1 | tr -dc '0-9')
PCT="${PCT:-0}"

# Pick color based on compaction proximity (ansi256 codes to match colorLevel 2)
if [ "$PCT" -lt 45 ]; then
  # Green (ansi256 78, a teal-green — git branch uses 155)
  NEW_FG='\x1b[38;5;78m'
elif [ "$PCT" -lt 70 ]; then
  # Yellow
  NEW_FG='\x1b[38;5;227m'
else
  # Red (autocompaction at 80%)
  NEW_FG='\x1b[38;5;203m'
fi

ESC=$(printf '\x1b')

echo "$OUTPUT" | sed \
  -e "s/${ESC}\[38;5;203m/${NEW_FG}/g" \
  -e 's|\.\.\./||g'
