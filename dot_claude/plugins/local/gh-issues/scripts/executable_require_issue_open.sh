#!/bin/bash
# Hook: On git checkout -b / switch -c, ensure a matching GH issue exists and is open.
# Event: PreToolUse (Bash)
# Convention: branch name prefix stripped → search GH issue titles
#
# Supports compound commands: gh issue create ... && git checkout -b ...
# Uses shfmt to parse the command AST so each sub-command is checked independently.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Check PATH for shfmt
if ! command -v shfmt &>/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
  source ~/.config/envman/PATH.env 2>/dev/null
fi

# Parse compound command into individual sub-commands using shfmt AST.
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

# Extract branch name from parsed sub-commands
TARGET=""
while IFS= read -r subcmd; do
  MATCH=$(echo "$subcmd" | sed -nE 's/^git\s+(checkout -b|switch (-c|--create)) ([^ ]+).*/\3/p')
  [ -n "$MATCH" ] && TARGET="$MATCH"
done <<< "$CMDS"

# No git checkout -b found — nothing to check
[ -z "$TARGET" ] && exit 0

# Skip protected branches
case "$TARGET" in
  main|dev) exit 0 ;;
esac

# Check if earlier sub-commands in the compound statement create a GH issue
HAS_GH_CREATE=0
while IFS= read -r subcmd; do
  if echo "$subcmd" | grep -qE "^gh\s+issue\s+create\b"; then
    HAS_GH_CREATE=1
  fi
done <<< "$CMDS"

if [ "$HAS_GH_CREATE" -eq 1 ]; then
  exit 0
fi

# Otherwise check that a matching open GH issue exists
source "$(dirname "$0")/helpers/resolve_issue.sh"
ISSUE_NUM=$(resolve_gh_issue "$TARGET")

if [ -z "$ISSUE_NUM" ]; then
  echo "Blocked: no GitHub issue found for branch '$TARGET'. Create one first:" >&2
  echo "  gh issue create --title \"Description\" --label \"${TARGET%%/*}\"" >&2
  exit 2
fi

# Check issue is open
STATE=$(gh issue view "$ISSUE_NUM" --json state --jq '.state' 2>/dev/null)

if [ "$STATE" != "OPEN" ]; then
  echo "Blocked: GitHub issue #$ISSUE_NUM is '$STATE', not open. Reopen it first:" >&2
  echo "  gh issue reopen $ISSUE_NUM" >&2
  exit 2
fi

exit 0
