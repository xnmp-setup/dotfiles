#!/bin/bash
# PreToolUse hook: blocks git commit on feat/ and fix/ branches if no test files are included.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only trigger on git commit
echo "$CMD" | grep -qE 'git\s+commit' || exit 0

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

# Only enforce on feature and fix branches
echo "$BRANCH" | grep -qE '^(feat|fix)/' || exit 0

# Skip if this branch was previously merged to dev (revisited branch)
# If the merge base is NOT on dev's first-parent line, the branch was already merged before
MERGE_BASE=$(git merge-base dev HEAD 2>/dev/null)
if [ -n "$MERGE_BASE" ] && ! git rev-list --first-parent dev 2>/dev/null | grep -qm1 "^${MERGE_BASE}$"; then
  exit 0
fi

# Check all files on this branch (committed + staged) vs dev
COMMITTED=$(git diff --name-only dev...HEAD 2>/dev/null)
STAGED=$(git diff --cached --name-only 2>/dev/null)
ALL_CHANGES=$(printf "%s\n%s" "$COMMITTED" "$STAGED" | sort -u)

# Check for test files on the branch
UNIT_COUNT=$(echo "$ALL_CHANGES" | grep -cE 'tests/.*\.test\.ts$' || true)
E2E_COUNT=$(echo "$ALL_CHANGES" | grep -cE 'e2e/.*\.spec\.ts$' || true)

# No source changes = nothing to test
SRC_COUNT=$(echo "$ALL_CHANGES" | grep -cE 'src/(lib|routes)/.*\.(ts|svelte)$' || true)
RUST_COUNT=$(echo "$ALL_CHANGES" | grep -cE 'src-tauri/src/.*\.rs$' || true)
SRC_TOTAL=$((SRC_COUNT + RUST_COUNT))
[ "$SRC_TOTAL" -eq 0 ] && exit 0

# Non-blocking reminder on first commit: consider unit tests
COMMITS_AHEAD=$(git rev-list --count dev..HEAD 2>/dev/null || echo "0")
if [ "$COMMITS_AHEAD" -eq 0 ] && [ "$UNIT_COUNT" -eq 0 ]; then
  echo "Reminder: consider adding unit tests if this change introduces new business logic." >&2
fi

# feat/ branches require an e2e test
if echo "$BRANCH" | grep -qE '^feat/'; then
  if [ "$E2E_COUNT" -eq 0 ]; then
    echo "Blocked: feat/ branch '$BRANCH' has $SRC_TOTAL changed source files but no e2e test." >&2
    echo "Add an e2e test (e2e/*.spec.ts) that verifies the feature before committing." >&2
    exit 2
  fi
fi

# fix/ branches require a regression test (unit or e2e)
if echo "$BRANCH" | grep -qE '^fix/'; then
  if [ "$UNIT_COUNT" -eq 0 ] && [ "$E2E_COUNT" -eq 0 ]; then
    echo "Blocked: fix/ branch '$BRANCH' has $SRC_TOTAL changed source files but no regression test." >&2
    echo "Add a unit test (tests/*.test.ts) or e2e test (e2e/*.spec.ts) that guards against this bug recurring." >&2
    exit 2
  fi
fi

exit 0
