#!/bin/bash
# Hook: Block merge if no docs/ files were modified on feature-like branches
# Event: PreToolUse (Bash)

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git merge
echo "$CMD" | grep -qE 'git\s+merge\s' || exit 0

# Extract branch: first arg after 'git merge' must not be a flag
MERGED=$(echo "$CMD" | sed -nE 's/.*git\s+merge\s+([^ ]+).*/\1/p')
if [ -z "$MERGED" ] || echo "$MERGED" | grep -qE '^-'; then
  echo "Blocked: use 'git merge <branch> [flags]' — branch name must come first." >&2
  exit 2
fi

# Only enforce on branches that should have docs
case "$MERGED" in
  feat/*|fix/*|bugfix/*|refactor/*|perf/*|breaking/*) ;;
  *) exit 0 ;;
esac

# Check if any docs/ files were modified on the branch vs dev
PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0

# Skip if this branch was previously merged to dev (revisited branch)
# If the merge base is NOT on dev's first-parent line, the branch was already merged before
MERGE_BASE=$(git -C "$PROJECT_ROOT" merge-base dev "$MERGED" 2>/dev/null)
if [ -n "$MERGE_BASE" ] && ! git -C "$PROJECT_ROOT" rev-list --first-parent dev 2>/dev/null | grep -qm1 "^${MERGE_BASE}$"; then
  exit 0
fi

DOCS_CHANGED=$(git -C "$PROJECT_ROOT" diff --name-only dev..."$MERGED" 2>/dev/null | grep -c '^docs/')

if [ "$DOCS_CHANGED" -eq 0 ]; then
  echo "Blocked: branch '$MERGED' has no changes in docs/." >&2
  echo "Update relevant docs (architecture, features, lessons_learnt, etc.) before merging." >&2
  exit 2
fi

exit 0
