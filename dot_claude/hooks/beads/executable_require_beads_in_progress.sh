#!/bin/bash
# Hook: On git checkout/switch, ensure the target branch has a matching
#        Beads issue that is marked in_progress.
# Event: PreToolUse (Bash)
# Convention: branch name IS the Beads issue ID (e.g. feat/add-sidebar)
#
# Supports compound commands: bd create ... && bd update ... && git checkout -b ...
# Uses shfmt to parse the command AST so each sub-command is checked independently.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on new branch creation (anywhere in the command)
echo "$CMD" | grep -qE 'git\s+(checkout\s+-b|switch\s+(-c|--create))' || exit 0

# Check PATH for shfmt
if ! command -v shfmt &>/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
  source ~/.config/envman/PATH.env 2>/dev/null
fi

# Parse compound command into individual sub-commands using shfmt AST.
# Recursively extracts Lit values to include quoted strings.
if command -v shfmt &>/dev/null; then
  CMDS=$(echo "$CMD" | shfmt --to-json 2>/dev/null \
    | jq -r '[.. | objects | select(.Type == "CallExpr") |
        [.Args[] | [.. | objects | select(.Type == "Lit") | .Value] | join("")] | join(" ")
      ] | .[]' 2>/dev/null)
else
  echo "Warning: shfmt not installed. Compound commands (&&) won't be parsed correctly." >&2
  echo "  Install: curl -sS https://webinstall.dev/shfmt | bash" >&2
fi

# Fallback if shfmt unavailable or parsing failed
[ -z "$CMDS" ] && CMDS="$CMD"

# Extract branch name from the git checkout -b sub-command
TARGET=""
while IFS= read -r subcmd; do
  MATCH=$(echo "$subcmd" | sed -nE 's/.*(checkout -b|switch (-c|--create)) ([^ ]+).*/\3/p')
  [ -n "$MATCH" ] && TARGET="$MATCH"
done <<< "$CMDS"

[ -z "$TARGET" ] && exit 0

# Skip protected branches
case "$TARGET" in
  main|dev) exit 0 ;;
esac

# Check if earlier sub-commands in the compound statement create and
# mark the issue in_progress — if so, allow the checkout
HAS_CREATE=0
HAS_IN_PROGRESS=0
while IFS= read -r subcmd; do
  if echo "$subcmd" | grep -qE "^bd create\b" && echo "$subcmd" | grep -qF "$TARGET"; then
    HAS_CREATE=1
  fi
  if echo "$subcmd" | grep -qE "^bd update\b.*--status in_progress" && echo "$subcmd" | grep -qF "$TARGET"; then
    HAS_IN_PROGRESS=1
  fi
done <<< "$CMDS"

if [ "$HAS_CREATE" -eq 1 ] && [ "$HAS_IN_PROGRESS" -eq 1 ]; then
  exit 0
fi

# Otherwise check the issue exists and is in_progress
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
