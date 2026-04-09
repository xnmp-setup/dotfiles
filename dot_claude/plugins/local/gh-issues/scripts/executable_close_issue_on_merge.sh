#!/bin/bash
# Hook: Auto-close the GitHub issue when its branch gets merged
# Event: PostToolUse (Bash)
# Convention: branch name maps to a GH issue via title search

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git merge
echo "$CMD" | grep -qE 'git\s+merge\s' || exit 0

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0

# Get the merged branch from the second parent of HEAD
MERGED=$(git -C "$PROJECT_ROOT" name-rev --name-only HEAD^2 2>/dev/null | sed 's|~.*||; s|remotes/origin/||')
[ -z "$MERGED" ] && exit 0

# Resolve branch name to GH issue number
source "$(dirname "$0")/helpers/resolve_issue.sh"
ISSUE_NUM=$(resolve_gh_issue "$MERGED")
if [ -z "$ISSUE_NUM" ]; then
  echo "Warning: no GitHub issue found for merged branch '$MERGED'." >&2
  exit 0
fi

STATE=$(gh issue view "$ISSUE_NUM" --json state --jq '.state' 2>/dev/null)
[ -z "$STATE" ] && exit 0

# Already closed
[ "$STATE" = "CLOSED" ] && exit 0

# Close with a comment summarizing branch commits
TARGET_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null)
MERGE_BASE=$(git -C "$PROJECT_ROOT" merge-base HEAD^1 HEAD^2 2>/dev/null)
if [ -n "$MERGE_BASE" ]; then
  BRANCH_MSGS=$(git -C "$PROJECT_ROOT" log --format="- %s" "$MERGE_BASE"..HEAD^2 2>/dev/null)
fi
CLOSE_REASON="${BRANCH_MSGS:-Merged to ${TARGET_BRANCH:-dev}}"

gh issue close "$ISSUE_NUM" --comment "$CLOSE_REASON" 2>/dev/null
echo "Auto-closed GitHub issue #$ISSUE_NUM (branch '$MERGED')." >&2
exit 0
