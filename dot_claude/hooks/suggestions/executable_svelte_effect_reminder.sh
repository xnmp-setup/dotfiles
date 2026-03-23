#!/bin/bash
# Hook: Remind to consider alternatives when $effect is used in Svelte files
# Event: PostToolUse (Edit|Write)

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0

case "$FILE" in
  *.svelte|*.svelte.ts) ;;
  *) exit 0 ;;
esac

# Check if the edited file contains $effect
grep -q '\$effect' "$FILE" 2>/dev/null || exit 0

echo "Reminder: this file uses \$effect. Consider whether \$derived, \$derived.by, or reactive assignments could achieve the same result. \$effect should be reserved for genuine side effects (DOM manipulation, external subscriptions)." >&2
exit 0
