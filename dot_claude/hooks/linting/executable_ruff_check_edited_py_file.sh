#!/bin/bash
# Hook: Run ruff linter on edited Python files
# Event: PostToolUse (Edit|Write)

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

case "$FILE" in
  *.py) ;;
  *) exit 0 ;;
esac

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0
[ ! -f "$PROJECT_ROOT/pyproject.toml" ] && exit 0

BASENAME=$(basename "$FILE")

RAW=$(cd "$PROJECT_ROOT" && ruff check "$FILE" 2>&1)
EXIT_CODE=$?

[ $EXIT_CODE -eq 0 ] && exit 0

echo "ruff issues in $BASENAME:" >&2
echo "$RAW" >&2
exit 2
