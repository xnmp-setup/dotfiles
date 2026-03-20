#!/bin/bash
# Hook: Block merge if required screenshots don't exist on disk
# Event: PreToolUse (Bash)
# Expects screenshots in screenshots/<branch>/ directory

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git merge
echo "$CMD" | grep -qE 'git\s+merge\b' || exit 0

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0

# Extract branch being merged
MERGED=$(echo "$CMD" | sed -nE 's/.*git\s+merge\s+[^ ]*\s+([^ ]+).*/\1/p')
[ -z "$MERGED" ] && MERGED=$(echo "$CMD" | grep -oE '[^ ]+$')
[ -z "$MERGED" ] && exit 0

# Branch name = beads issue ID
DESC=$(bd show "$MERGED" --json 2>/dev/null | jq -r '.[0].description // empty' 2>/dev/null)
[ -z "$DESC" ] && exit 0

# No screenshot section = skip
echo "$DESC" | grep -qiE '##\s*Screenshots' || exit 0

# Check for "none required" — allow merge
if echo "$DESC" | grep -qiE 'none required'; then
  exit 0
fi

# Count required screenshots (list items under ## Screenshots)
REQUIRED=$(echo "$DESC" | sed -n '/##\s*[Ss]creenshots/,/^##/p' | grep -cE '^\s*-\s' || true)
[ "$REQUIRED" -eq 0 ] && exit 0

# Check for actual screenshot files
SCREENSHOT_DIR="$PROJECT_ROOT/screenshots/$MERGED"
if [ ! -d "$SCREENSHOT_DIR" ]; then
  echo "Blocked: no screenshots found for '$MERGED'." >&2
  echo "Expected directory: screenshots/$MERGED/" >&2
  echo "Take $REQUIRED screenshot(s) with agent-browser and save them there." >&2
  exit 2
fi

ACTUAL=$(find "$SCREENSHOT_DIR" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) 2>/dev/null | wc -l)

if [ "$ACTUAL" -lt "$REQUIRED" ]; then
  echo "Blocked: issue '$MERGED' requires $REQUIRED screenshot(s) but only $ACTUAL found in screenshots/$MERGED/." >&2
  exit 2
fi

exit 0
