#!/bin/bash
# Hook: Git workflow rules
# Event: PreToolUse (Bash)
# Rules:
#   1. Block git add on protected branches (main/dev)
#   2. Require --no-ff on git merge
#   3. Enforce branch naming convention on new branches
#   4. Require descriptive merge commit message

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

PROJECT_ROOT=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$PROJECT_ROOT" ] && exit 0
[ ! -d "$PROJECT_ROOT/.git" ] && exit 0

# Rule 1: Block git add on protected branches
if echo "$CMD" | grep -qE 'git\s+add\b'; then
  BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
  case "$BRANCH" in
    main|dev)
      echo "Blocked: cannot stage files on protected branch '$BRANCH'. Create a branch first." >&2
      exit 2
      ;;
  esac
fi

# Rule 2: Require merge commits (--no-ff)
if echo "$CMD" | grep -qE 'git\s+merge\b'; then
  if ! echo "$CMD" | grep -qF -- '--no-ff'; then
    echo "Blocked: merges must use --no-ff to create a merge commit." >&2
    exit 2
  fi
fi

# Rule 4: Require descriptive merge commit message
if echo "$CMD" | grep -qE 'git\s+merge\b'; then
  if ! echo "$CMD" | grep -qE '\-m\s'; then
    echo "Blocked: merge must include a descriptive commit message via -m." >&2
    echo "Summarise what was achieved, not just 'Merge branch X'." >&2
    exit 2
  fi
  # Block default/boilerplate messages
  MSG=$(echo "$CMD" | sed -nE 's/.*-m\s+["'"'"']([^"'"'"']+)["'"'"'].*/\1/p')
  if echo "$MSG" | grep -qiE '^Merge branch'; then
    echo "Blocked: merge commit message looks like boilerplate ('$MSG')." >&2
    echo "Write a human-readable summary of what this branch achieved." >&2
    exit 2
  fi
fi

# Rule 3: Enforce branch naming convention
NEWBRANCH=$(echo "$CMD" | sed -nE 's/.*git\s+(checkout\s+-b|switch\s+(-c|--create))\s+([^ ]+).*/\3/p')
if [ -n "$NEWBRANCH" ]; then
  case "$NEWBRANCH" in
    feat/*|fix/*|bugfix/*|refactor/*|perf/*|breaking/*|chore/*|test/*|docs/*|style/*) ;;
    *)
      echo "Blocked: branch '$NEWBRANCH' must start with a valid prefix." >&2
      echo "Allowed: feat/, fix/, bugfix/, refactor/, perf/, breaking/, chore/, test/, docs/, style/" >&2
      exit 2
      ;;
  esac
fi

exit 0
