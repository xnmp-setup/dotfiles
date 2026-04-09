#!/bin/bash
# Hook: Auto-close the Beads issue when its branch gets merged
# Event: PostToolUse (Bash)
# Convention: branch name IS the Beads issue ID

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git merge
echo "$CMD" | grep -qE 'git\s+merge\s' || exit 0

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0

# Extract the merged branch from the merge commit message (set by git)
# Format: "Merge branch 'feat/foo'" or custom message
# More robust: get the second parent of HEAD (the merged branch) and resolve its name
MERGED=$(git -C "$PROJECT_ROOT" name-rev --name-only HEAD^2 2>/dev/null | sed 's|~.*||; s|remotes/origin/||')
[ -z "$MERGED" ] && exit 0

# Resolve branch name to beads issue ID
source "$(dirname "$0")/helpers/resolve_issue.sh"
ISSUE_ID=$(resolve_beads_issue "$MERGED")
if [ -z "$ISSUE_ID" ]; then
  echo "Warning: no Beads issue found for merged branch '$MERGED'. Consider creating one." >&2
  exit 0
fi

JSON=$(bd show "$ISSUE_ID" --json 2>/dev/null)
STATUS=$(echo "$JSON" | jq -r '.[0].status // empty' 2>/dev/null)
if [ -z "$STATUS" ]; then
  echo "Warning: could not read status for Beads issue '$ISSUE_ID'." >&2
  exit 0
fi

# Already closed
[ "$STATUS" = "closed" ] && exit 0

# Close with a summary of all branch commit messages as the reason
TARGET_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null)
MERGE_BASE=$(git -C "$PROJECT_ROOT" merge-base HEAD^1 HEAD^2 2>/dev/null)
if [ -n "$MERGE_BASE" ]; then
  BRANCH_MSGS=$(git -C "$PROJECT_ROOT" log --format="- %s" "$MERGE_BASE"..HEAD^2 2>/dev/null)
fi
CLOSE_REASON="${BRANCH_MSGS:-Merged to ${TARGET_BRANCH:-dev}}"
bd close "$ISSUE_ID" --reason "$CLOSE_REASON" 2>/dev/null
echo "Auto-closed Beads issue '$ISSUE_ID' (branch '$MERGED')." >&2
exit 0
