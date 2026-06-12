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

echo "$OUTPUT" \
  | sed \
      -e "s/${ESC}\[38;5;203m/${NEW_FG}/g" \
      -e 's|\.\.\./||g' \
  | python3 -c '
import sys, re

FAMILIES = ("Opus", "Sonnet", "Haiku", "Fable")
SEP = "\xa0|\xa0"  # NBSP | NBSP separator used by ccstatusline

def shorten_model(text):
    lo = text.lower()
    for name in FAMILIES:
        if name.lower() in lo:
            return name
    return text

for line in sys.stdin:
    # strip "no git" and the orphaned separator+color it leaves behind
    line = line.replace("⎇\xa0no\xa0git", "")
    line = re.sub(r"\xa0\|\xa0\x1b\[[0-9;]+m\x1b\[39m", "", line)
    # shorten model name to just the family
    line = re.sub(r"(\x1b\[[0-9;]+m)([^\x1b]+)", lambda m: m.group(1) + shorten_model(m.group(2)), line)
    # 1000k -> 1m
    line = re.sub(r"(\d+)000k", r"\g<1>m", line)
    sys.stdout.write(line)
'
