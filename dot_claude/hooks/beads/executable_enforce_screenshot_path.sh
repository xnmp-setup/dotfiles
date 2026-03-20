#!/bin/bash
# Hook: Ensure agent-browser screenshots are saved to the correct directory
# Event: PreToolUse (Bash)
# Expected path: screenshots/<branch>/

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on agent-browser screenshot
echo "$CMD" | grep -qE 'agent-browser\s+screenshot' || exit 0

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0
[ ! -d "$PROJECT_ROOT/.git" ] && exit 0

BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
case "$BRANCH" in
  main|dev) exit 0 ;;
esac

EXPECTED="screenshots/$BRANCH/"

# Extract the path argument (after "screenshot", skip flags)
SAVE_PATH=$(echo "$CMD" | sed -nE 's/.*agent-browser\s+screenshot\s+(--full\s+|-f\s+)?([^ -][^ ]*).*/\2/p')

if [ -z "$SAVE_PATH" ]; then
  echo "Blocked: screenshot must be saved to $EXPECTED" >&2
  echo "Usage: agent-browser screenshot ${EXPECTED}descriptive-name.png" >&2
  exit 2
fi

# Check path starts with expected directory
case "$SAVE_PATH" in
  screenshots/$BRANCH/*) exit 0 ;;
  *)
    echo "Blocked: screenshot path '$SAVE_PATH' is not in the expected directory." >&2
    echo "Save to: ${EXPECTED}<descriptive-name>.png" >&2
    exit 2
    ;;
esac
