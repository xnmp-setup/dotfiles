#!/bin/bash
# Hook: Block merge if no docs/ files were modified on feature-like branches
# Event: PreToolUse (Bash)

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git merge
echo "$CMD" | grep -qE 'git\s+merge\b' || exit 0

# Extract branch being merged
MERGED=$(echo "$CMD" | sed -nE 's/.*git\s+merge\s+[^ ]*\s+([^ ]+).*/\1/p')
[ -z "$MERGED" ] && MERGED=$(echo "$CMD" | grep -oE '[^ ]+$')
[ -z "$MERGED" ] && exit 0

# Only enforce on branches that should have docs
case "$MERGED" in
  feat/*|fix/*|bugfix/*|refactor/*|perf/*|breaking/*) ;;
  *) exit 0 ;;
esac

# Check if any docs/ files were modified on the branch vs dev
PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0

DOCS_CHANGED=$(git -C "$PROJECT_ROOT" diff --name-only dev..."$MERGED" 2>/dev/null | grep -c '^docs/')

if [ "$DOCS_CHANGED" -eq 0 ]; then
  echo "Blocked: branch '$MERGED' has no changes in docs/." >&2
  echo "Update relevant docs (architecture, features, lessons_learnt, etc.) before merging." >&2
  exit 2
fi

exit 0
