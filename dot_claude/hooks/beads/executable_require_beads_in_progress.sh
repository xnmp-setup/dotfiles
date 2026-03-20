#!/bin/bash
# Hook: On git checkout/switch, ensure the target branch has a matching
#        Beads issue that is marked in_progress.
# Event: PreToolUse (Bash)
# Convention: branch name IS the Beads issue ID (e.g. feat/add-sidebar)

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on new branch creation
TARGET=$(echo "$CMD" | sed -nE 's/.*git\s+(checkout\s+-b|switch\s+(-c|--create))\s+([^ ]+).*/\3/p')
[ -z "$TARGET" ] && exit 0

# Skip protected branches
case "$TARGET" in
  main|dev) exit 0 ;;
esac

# Check issue via JSON
JSON=$(bd show "$TARGET" --json 2>/dev/null) || JSON=""
STATUS=$(echo "$JSON" | jq -r '.[0].status // empty' 2>/dev/null)

if [ -z "$STATUS" ]; then
  echo "Blocked: no Beads issue found for branch '$TARGET'. Create one first:" >&2
  echo "  bd create \"Description\" --id \"$TARGET\"" >&2
  exit 2
fi

if [ "$STATUS" != "in_progress" ]; then
  echo "Blocked: issue '$TARGET' is '$STATUS', not in_progress. Run:" >&2
  echo "  bd update $TARGET --status in_progress" >&2
  exit 2
fi

exit 0
