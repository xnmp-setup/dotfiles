#!/bin/bash
# Hook: Block edits to tracked files on protected branches (main/dev)
# Event: PreToolUse (Edit|Write)

INPUT=$(cat)
PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0

# Only applies to git repos
[ ! -d "$PROJECT_ROOT/.git" ] && exit 0

BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)

case "$BRANCH" in
  main|dev) ;;
  *) exit 0 ;;
esac

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

# Only block if file is tracked by git
git -C "$PROJECT_ROOT" ls-files --error-unmatch "$FILE" >/dev/null 2>&1 || exit 0

echo "Blocked: cannot edit tracked file on protected branch '$BRANCH'. Create a branch first." >&2
exit 2
