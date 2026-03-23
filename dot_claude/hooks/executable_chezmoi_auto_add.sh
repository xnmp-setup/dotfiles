#!/bin/bash
# Hook: Auto-add modified ~/.claude/ files to chezmoi
# Event: PostToolUse (Edit, Write)

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only trigger on file modifications
case "$TOOL" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

# Only trigger for files under ~/.claude/
case "$FILE" in
  /home/*/\.claude/*|"$HOME"/.claude/*) ;;
  *) exit 0 ;;
esac

# Skip MEMORY.md and memory files (ephemeral, not worth tracking)
case "$FILE" in
  */memory/*|*/MEMORY.md) exit 0 ;;
esac

chezmoi add "$FILE" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "Auto-added $FILE to chezmoi." >&2
fi

exit 0
