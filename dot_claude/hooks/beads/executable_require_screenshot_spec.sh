#!/bin/bash
# Hook: Ensure beads issue has screenshot spec before marking in_progress
# Event: PostToolUse (Bash)
# Checks after bd update --status in_progress

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on bd update with in_progress
echo "$CMD" | grep -qE 'bd\s+update\b' || exit 0
echo "$CMD" | grep -qF 'in_progress' || exit 0

# Extract issue ID (first non-flag argument after bd update)
ISSUE_ID=$(echo "$CMD" | sed -nE 's/.*bd\s+update\s+([^ -][^ ]*).*/\1/p')
[ -z "$ISSUE_ID" ] && exit 0

# Get issue description
DESC=$(bd show "$ISSUE_ID" --json 2>/dev/null | jq -r '.[0].description // empty' 2>/dev/null)

# Check for screenshot spec section
if echo "$DESC" | grep -qiE '##\s*Screenshots'; then
  exit 0
fi

echo "Blocked: issue '$ISSUE_ID' has no screenshot specification." >&2
echo "Any issue that results in a change to UI behaviour needs screenshots verifying the change." >&2
echo "Add a '## Screenshots' section to the issue description with either:" >&2
echo "  - List of screenshots that verify the UI change (e.g. '- sidebar in collapsed state')" >&2
echo "  - 'None required' with a reason (e.g. backend-only, no UI impact)" >&2
echo "Screenshots must be saved to: screenshots/$ISSUE_ID/" >&2
exit 2
