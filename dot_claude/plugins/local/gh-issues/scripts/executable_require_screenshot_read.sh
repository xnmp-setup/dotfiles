#!/bin/bash
# PreToolUse:Bash — block git commit if screenshots were taken but not Read.
# Scans the session transcript for screenshot commands, then checks only
# the ones that are STAGED for this commit. Unverified staged screenshots
# must be Read before committing.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git commit (check parsed sub-commands, not raw text)
if ! command -v shfmt &>/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
  source ~/.config/envman/PATH.env 2>/dev/null
fi

if command -v shfmt &>/dev/null; then
  CMDS=$(echo "$CMD" | shfmt --to-json 2>/dev/null \
    | jq -r '[.. | objects | select(.Type == "CallExpr") |
        [.Args[] | [.. | objects | select(.Type == "Lit") | .Value] | join("")] | join(" ")
      ] | .[]' 2>/dev/null)
fi
[ -z "$CMDS" ] && CMDS="$CMD"

# Check if any sub-command is a git commit
echo "$CMDS" | grep -qE '^git commit\b' || exit 0

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Get staged screenshot files
STAGED=$(git diff --cached --name-only 2>/dev/null | grep -E 'screenshots/.*\.(png|jpg|webp)$')

# Also detect screenshots being added in a compound command (git add ... && git commit ...)
# These won't show in --cached yet since add hasn't executed
ADD_SHOTS=""
while IFS= read -r subcmd; do
  if echo "$subcmd" | grep -qE '^git add\b'; then
    # Extract file paths (non-flag args after "git add")
    PATHS=$(echo "$subcmd" | tr ' ' '\n' | grep -vE '^(git|add|-|$)' | grep -E 'screenshots/.*\.(png|jpg|webp)$')
    [ -n "$PATHS" ] && ADD_SHOTS=$(printf "%s\n%s" "$ADD_SHOTS" "$PATHS")
  fi
done <<< "$CMDS"

ALL_SHOTS=$(printf "%s\n%s" "$STAGED" "$ADD_SHOTS" | sort -u | grep -v '^$')
[ -z "$ALL_SHOTS" ] && exit 0

# Extract all file paths passed to Read tool calls in this session
READ_FILES=$(jq -r '
  select(.type == "assistant") |
  .message.content[]? |
  select(.type == "tool_use" and .name == "Read") |
  .input.file_path // empty
' "$TRANSCRIPT" 2>/dev/null | sort -u)

# Check each staged screenshot was Read
MISSING=""
while IFS= read -r SHOT; do
  [ -z "$SHOT" ] && continue
  if ! echo "$READ_FILES" | grep -qF "$SHOT"; then
    MISSING="${MISSING}  ${SHOT}\n"
  fi
done <<< "$ALL_SHOTS"

if [ -n "$MISSING" ]; then
  echo "Blocked: unverified screenshot(s) staged for commit. Read each to confirm it shows the feature." >&2
  printf "%b" "$MISSING" >&2
  echo "Use the Read tool on each path above, then retry." >&2
  exit 2
fi

exit 0
