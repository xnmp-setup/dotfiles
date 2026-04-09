#!/bin/bash
# Hook: Ensure GH issue has a screenshot spec before creating a feature branch
# Event: PostToolUse (Bash)
# Triggers after successful git checkout -b / switch -c
# Warns (but doesn't block) if the issue body has no ## Screenshots section

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git checkout -b / switch -c
echo "$CMD" | grep -qE 'git\s+(checkout -b|switch (-c|--create))' || exit 0

# Extract branch name
TARGET=$(echo "$CMD" | sed -nE 's/.*git\s+(checkout -b|switch (-c|--create)) ([^ ]+).*/\3/p')
[ -z "$TARGET" ] && exit 0

# Skip protected branches
case "$TARGET" in
  main|dev) exit 0 ;;
esac

# Resolve branch name to GH issue number
source "$(dirname "$0")/helpers/resolve_issue.sh"
ISSUE_NUM=$(resolve_gh_issue "$TARGET")
[ -z "$ISSUE_NUM" ] && exit 0

# Get issue body
BODY=$(gh issue view "$ISSUE_NUM" --json body --jq '.body' 2>/dev/null)

# Check for screenshot spec section
if echo "$BODY" | grep -qiE '##\s*Screenshots'; then
  exit 0
fi

echo "Warning: GitHub issue #$ISSUE_NUM has no screenshot specification." >&2
echo "Any issue that results in a change to UI behaviour needs screenshots verifying the change." >&2
echo "Add a '## Screenshots' section to the issue body with either:" >&2
echo "  - List of screenshots that verify the UI change (e.g. '- sidebar in collapsed state')" >&2
echo "  - 'None required' with a reason (e.g. backend-only, no UI impact)" >&2
echo "Screenshots must be saved to: screenshots/$TARGET/" >&2
exit 2
