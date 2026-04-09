#!/bin/bash
# SessionStart hook: inject GitHub Issues workflow instructions into context

cat << 'EOF'
## Issue Tracking (GitHub Issues)

Key commands:
- `gh issue create --title "Title" --body "Description"` — create issue
- `gh issue list` — list open issues
- `gh issue list --state all` — list all issues
- `gh issue view <number>` — view issue details (`--json` for machine-readable)
- `gh issue edit <number> --body "new body"` — update description
- `gh issue comment <number> --body "notes"` — add notes
- `gh issue close <number> --comment "why"` — close issue (automated by merge hook)
- `gh extension install jwilger/gh-issue-ext` — install if missing
- `gh issue-ext blocking add <blocked> <blocker>` — mark issue as blocked by another
- `gh issue-ext blocking list <number>` — list blocking relationships
- `gh issue-ext sub add <parent> <child>` — add sub-issue
- `gh issue-ext show <number>` — show all relationships

Convention: branch names map to issues by title. Branch `feat/my-feature` matches an issue whose title contains "my-feature". A hook validates that a matching open issue exists before allowing branch creation.

### Screenshot Requirements

When creating issues, include a `## Screenshots` section in the issue body with markdown checkboxes (e.g., `- [ ] sidebar`). Screenshots must be saved to `screenshots/<branch>/`. The merge hook verifies they exist. Use 'None required' only for pure backend/refactor changes with no user-visible effect. Behavioral fixes still need a screenshot showing the corrected behavior.

### Per-Issue Checklist

1. Create a GitHub issue (with `## Screenshots` section in the body)
2. Create a branch (hook validates a matching open issue exists)
3. Implement, then run tests and fix failures
4. Take required screenshots; verify they capture working functionality
5. Create E2E tests if needed
6. Update docs as appropriate
7. Merge with a descriptive merge commit
EOF
