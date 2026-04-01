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

# Extract branch name from parsed sub-commands (not raw command text)
TARGET=""
while IFS= read -r subcmd; do
  MATCH=$(echo "$subcmd" | sed -nE 's/^git\s+(checkout -b|switch (-c|--create)) ([^ ]+).*/\3/p')
  [ -n "$MATCH" ] && TARGET="$MATCH"
done <<< "$CMDS"

# No git checkout -b found in any actual sub-command — nothing to check
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
source "$(dirname "$0")/helpers/resolve_issue.sh"
ISSUE_ID=$(resolve_beads_issue "$TARGET")

if [ -z "$ISSUE_ID" ]; then
  echo "Blocked: no Beads issue found for branch '$TARGET'. Create one first:" >&2
  echo "  bd create \"Description\" --id \"$TARGET\"" >&2
  exit 2
fi

STATUS=$(bd show "$ISSUE_ID" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null)

if [ "$STATUS" != "in_progress" ]; then
  echo "Blocked: issue '$ISSUE_ID' is '$STATUS', not in_progress. Run:" >&2
  echo "  bd update $ISSUE_ID --status in_progress" >&2
  exit 2
fi

exit 0
