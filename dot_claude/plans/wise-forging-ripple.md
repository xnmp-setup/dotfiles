# Fix 4 Hook Bugs

## Context
Testing hooks revealed 4 bugs where hooks either match too broadly, reference missing scripts, or can be bypassed.

## Bug 1: `block_force_push_delete.sh` — regex matches branch name anywhere in command

**File:** `~/.claude/hooks/git/block_force_push_delete.sh`

**Problem:** `grep -qE "\b(main|dev)\b"` matches `main`/`dev` anywhere in the command string — e.g. `git push -f origin feat/dev-tools` would be blocked because "dev" appears in the branch name.

**Fix:** Parse the actual push target branch rather than scanning the whole command. For `git push -f`, extract the refspec argument. For `git branch -D`, extract the branch name argument.

```bash
# Force push: extract the last argument (refspec/branch) from git push
if echo "$command" | grep -qE 'git\s+push\s+.*(-f|--force|--force-with-lease)'; then
  # Extract the branch: last non-flag argument after the remote
  PUSH_BRANCH=$(echo "$command" | sed -nE 's/.*git\s+push\s+[^ ]+\s+([^ -][^ ]*).*/\1/p' | sed 's/.*://')
  # Also check if remote itself is a protected branch name (git push -f main)
  PUSH_REMOTE=$(echo "$command" | sed -nE 's/.*git\s+push\s+(-f|--force|--force-with-lease)\s+([^ ]+).*/\2/p')
  if echo "$PUSH_BRANCH" | grep -qE "^(main|dev)$" || echo "$PUSH_REMOTE" | grep -qE "^(main|dev)$"; then
    ...block...
  fi
fi

# Branch delete: extract branch name after -d/-D flag
if echo "$command" | grep -qE 'git\s+branch\s+.*-(d|D)\b'; then
  DEL_BRANCH=$(echo "$command" | sed -nE 's/.*git\s+branch\s+-(d|D)\s+([^ ]+).*/\2/p')
  if echo "$DEL_BRANCH" | grep -qE "^(main|dev)$"; then
    ...block...
  fi
fi
```

## Bug 2: `run_e2e_for_merge.sh` — references nonexistent `test:e2e` script

**File:** `.claude/hooks/run_e2e_for_merge.sh`

**Problem:** Runs `bun run test:e2e` but `package.json` only has `"test": "vitest run"`. No `test:e2e` script exists.

**Fix:** Replace with `bunx playwright test` which is the standard way to run Playwright e2e tests in this project (confirmed by CLAUDE.md mentioning `npx playwright test`).

## Bug 3: `require_beads_in_progress.sh` — scans full command text including heredocs

**File:** `~/.claude/hooks/beads/require_beads_in_progress.sh`

**Problem:** The initial trigger check `echo "$CMD" | grep -qE 'git\s+(checkout\s+-b|switch\s+(-c|--create))'` scans the entire command string. If a heredoc or quoted string contains "git checkout -b", it triggers falsely.

**Fix:** Use the shfmt-parsed sub-commands for the trigger check too, not just for branch extraction. If shfmt is available, only check actual `git` CallExpr nodes. If shfmt unavailable, the existing behavior is an acceptable fallback.

```bash
# After shfmt parsing, check if ANY sub-command is a git checkout -b
HAS_CHECKOUT=0
while IFS= read -r subcmd; do
  if echo "$subcmd" | grep -qE '^git\s+(checkout\s+-b|switch\s+(-c|--create))'; then
    HAS_CHECKOUT=1
    break
  fi
done <<< "$CMDS"
[ "$HAS_CHECKOUT" -eq 0 ] && exit 0
```

## Bug 4: `require_screenshot_read.sh` — bypassed when screenshots added+committed in same command

**File:** `~/.claude/hooks/agent-browser/require_screenshot_read.sh`

**Problem:** The hook checks `git diff --cached --name-only` to find staged screenshots. But if screenshots are `git add`ed and `git commit`ted in the same compound command (`git add screenshots/... && git commit ...`), the `git diff --cached` runs before the `add` executes, so no screenshots are staged yet when the hook checks.

**Fix:** Also extract screenshot paths from `git add` sub-commands in the same compound command and treat them as staged.

```bash
# Parse compound command to find git-add'd screenshot files
ADD_SHOTS=""
if echo "$CMD" | grep -qE '&&|;'; then
  # Extract paths from "git add" sub-commands that match screenshot patterns
  ADD_SHOTS=$(echo "$CMD" | grep -oE 'git\s+add\s+[^&;]+' | 
    sed 's/git\s*add\s*//' | tr ' ' '\n' |
    grep -E 'screenshots/.*\.(png|jpg|webp)$')
fi

# Combine with already-staged screenshots
ALL_SHOTS=$(printf "%s\n%s" "$STAGED" "$ADD_SHOTS" | sort -u | grep -v '^$')
[ -z "$ALL_SHOTS" ] && exit 0
```

## Verification

After fixing, test each hook by triggering the exact scenarios:
1. `git push -f origin feat/dev-tools` — should NOT be blocked (dev in branch name, not target)
2. `git push -f origin dev` — SHOULD be blocked
3. On `dev`: `git merge feat/x --no-ff -m 'feat: x'` — e2e tests should actually run (playwright)
4. Bash command with heredoc containing "git checkout -b" — should NOT trigger beads check
5. `git add screenshots/... && git commit -m '...'` — should still require Read verification
