#!/usr/bin/env bash
# Hook: Block branch deletion and force pushing for protected branches (main, dev)
# Event: PreToolUse (Bash)

command=$(jq -r '.tool_input.command // ""')

is_protected() {
  case "$1" in
    main|dev) return 0 ;;
    *) return 1 ;;
  esac
}

# Ensure shfmt is on PATH
if ! command -v shfmt &>/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
  source ~/.config/envman/PATH.env 2>/dev/null
fi

# Parse compound command into individual sub-commands using shfmt AST
if command -v shfmt &>/dev/null; then
  CMDS=$(echo "$command" | shfmt --to-json 2>/dev/null \
    | jq -r '[.. | objects | select(.Type == "CallExpr") |
        [.Args[] | [.. | objects | select(.Type == "Lit") | .Value] | join("")] | join(" ")
      ] | .[]' 2>/dev/null)
fi
[ -z "$CMDS" ] && CMDS="$command"

while IFS= read -r subcmd; do
  # Block force push to protected branches
  if echo "$subcmd" | grep -qE '^git push\b' && echo "$subcmd" | grep -qE '(-f|--force|--force-with-lease)'; then
    # Extract args: remove flags, "git", "push" — remaining are [remote] [refspec...]
    ARGS=$(echo "$subcmd" | tr ' ' '\n' | grep -vE '^(git|push|-|$)')
    # The branch target is the last arg; strip local: prefix from refspecs like local:remote
    PUSH_BRANCH=$(echo "$ARGS" | tail -1 | sed 's/.*://')
    if [ -n "$PUSH_BRANCH" ] && is_protected "$PUSH_BRANCH"; then
      echo "Blocked: force pushing to a protected branch ('$PUSH_BRANCH') is not allowed." >&2
      exit 2
    fi
  fi

  # Block deletion of protected branches
  if echo "$subcmd" | grep -qE '^git branch\b' && echo "$subcmd" | grep -qE '\s-(d|D)\b'; then
    # Extract branch name: non-flag args after "git branch", excluding -d/-D
    DEL_BRANCH=$(echo "$subcmd" | tr ' ' '\n' | grep -vE '^(git|branch|-|$)' | tail -1)
    if [ -n "$DEL_BRANCH" ] && is_protected "$DEL_BRANCH"; then
      echo "Blocked: deleting a protected branch ('$DEL_BRANCH') is not allowed." >&2
      exit 2
    fi
  fi
done <<< "$CMDS"

exit 0
