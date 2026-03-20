#!/usr/bin/env bash
# Hook: Block branch deletion and force pushing for protected branches (main, dev)
# Event: PreToolUse (Bash)

PROTECTED="main|dev"

command=$(jq -r '.tool_input.command // ""')

# Block force push to protected branches
if echo "$command" | grep -qE 'git\s+push\s+.*(-f|--force|--force-with-lease)'; then
  if echo "$command" | grep -qE "\b($PROTECTED)\b"; then
    echo "Blocked: force pushing to a protected branch (main/dev) is not allowed." >&2
    exit 2
  fi
fi

# Block deletion of protected branches
if echo "$command" | grep -qE 'git\s+branch\s+.*-(d|D)\b'; then
  if echo "$command" | grep -qE "\b($PROTECTED)\b"; then
    echo "Blocked: deleting a protected branch (main/dev) is not allowed." >&2
    exit 2
  fi
fi

exit 0
