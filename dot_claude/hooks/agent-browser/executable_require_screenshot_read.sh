#!/bin/bash
# PreToolUse:Bash — block git commit if screenshots were taken but not Read.
# Scans the session transcript for screenshot commands, then checks only
# the ones that are STAGED for this commit. Unverified staged screenshots
# must be Read before committing.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git commit
echo "$CMD" | grep -qE 'git\s+commit' || exit 0

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Get staged screenshot files
STAGED=$(git diff --cached --name-only 2>/dev/null | grep -E 'screenshots/.*\.(png|jpg|webp)$')
[ -z "$STAGED" ] && exit 0

# Extract all file paths passed to Read tool calls in this session
READ_FILES=$(jq -r '
  select(.type == "assistant") |
  .message.content[]? |
  select(.type == "tool_use" and .name == "Read") |
  .input.file_path // empty
' "$TRANSCRIPT" 2>/dev/null | sort -u)

# Check each staged screenshot was Read
MISSING=""
while IFS= read -r SHOT; do
  [ -z "$SHOT" ] && continue
  if ! echo "$READ_FILES" | grep -qF "$SHOT"; then
    MISSING="${MISSING}  ${SHOT}\n"
  fi
done <<< "$STAGED"

if [ -n "$MISSING" ]; then
  echo "Blocked: unverified screenshot(s) staged for commit. Read each to confirm it shows the feature." >&2
  printf "%b" "$MISSING" >&2
  echo "Use the Read tool on each path above, then retry." >&2
  exit 2
fi

exit 0
