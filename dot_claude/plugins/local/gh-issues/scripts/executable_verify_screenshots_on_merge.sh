#!/bin/bash
# Hook: Block merge if required screenshots don't exist on disk
# Event: PreToolUse (Bash)
# Expects screenshots in screenshots/<branch>/ directory
# Reads screenshot spec from GitHub issue body

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git merge
echo "$CMD" | grep -qE 'git\s+merge\s' || exit 0

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0

# Extract branch: first arg after 'git merge' must not be a flag
MERGED=$(echo "$CMD" | sed -nE 's/.*git\s+merge\s+([^ ]+).*/\1/p')
if [ -z "$MERGED" ] || echo "$MERGED" | grep -qE '^-'; then
  echo "Blocked: use 'git merge <branch> [flags]' — branch name must come first." >&2
  exit 2
fi

# Resolve branch name to GH issue number
source "$(dirname "$0")/helpers/resolve_issue.sh"
ISSUE_NUM=$(resolve_gh_issue "$MERGED")
[ -z "$ISSUE_NUM" ] && exit 0

BODY=$(gh issue view "$ISSUE_NUM" --json body --jq '.body' 2>/dev/null)
[ -z "$BODY" ] && exit 0

# No screenshot section = skip
echo "$BODY" | grep -qiE '##\s*Screenshots' || exit 0

# Check for "none required" — allow merge
if echo "$BODY" | grep -qiE 'none required'; then
  exit 0
fi

# Count required screenshots (list items under ## Screenshots)
REQUIRED=$(echo "$BODY" | sed -n '/##\s*[Ss]creenshots/,/^##/p' | grep -cE '^\s*-\s' || true)
[ "$REQUIRED" -eq 0 ] && exit 0

# Check for screenshot files in the source branch's git tree (not the working directory)
ACTUAL=$(git -C "$PROJECT_ROOT" ls-tree -r --name-only "$MERGED" -- "screenshots/$MERGED/" 2>/dev/null \
  | grep -cE '\.(png|jpg|webp)$' || true)

if [ "$ACTUAL" -lt "$REQUIRED" ]; then
  echo "Blocked: branch '$MERGED' requires $REQUIRED screenshot(s) but only $ACTUAL found committed in screenshots/$MERGED/." >&2
  echo "Take screenshots with agent-browser, commit them to the feature branch, then merge." >&2
  exit 2
fi

exit 0
