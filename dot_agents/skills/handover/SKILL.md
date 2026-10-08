---
name: handover
description: "When asked for /handover, $handover, or a session handover, commit all WIP, update the active GitHub issue with remaining work, and write a comprehensive document for the next agent."
---

# Handover

Execute when the user requests a handover. This authorizes local commits, the handover document, and the active issue update. Use any supplied issue number/URL or destination; otherwise infer them from the session and repository conventions. Work in the current session so conversation context is preserved.

1. **Inspect.** Read repository instructions, status, staged/unstaged diffs, untracked files, branch/worktree, and recent commits. Identify the active open GitHub issue from session context or branch/PR links; verify its repository and state. If ambiguous, ask which issue while continuing local preservation. Do not create or reopen an issue.

2. **Commit all WIP.** Include legitimate pre-existing and current work, deletions, and new files in the affected repositories. Coordinate with concurrent writers; checkpoint participating submodules before their parents. Review and stage explicit paths, excluding secrets and disposable caches/build output. Run relevant checks or record applicable recent results, failures, and skipped checks. Make descriptive WIP commits using normal hooks. Do not discard work, bypass hooks, rewrite history, or push without existing authorization. Record SHAs and local-only/pushed status. If committing fails, preserve the index and files and report the blocker.

3. **Write the handover.** Follow the repository's established location; otherwise use `docs/handovers/YYYY-MM-DD-HHMMSSZ-issue-N.md` (task slug if no issue). Keep it durable, unique, and comprehensive enough to resume without this chat. Include:
   - Goal, acceptance criteria, constraints, and user decisions.
   - Repository/worktree, branch, code checkpoint SHAs, issue/PR links, and remote availability.
   - Completed behavior, important files, architecture/decisions, evidence, failed approaches, and pitfalls.
   - Exact validation/reproduction commands, outcomes, and what revision they cover.
   - Prioritized remaining work, dependencies, blockers, and observable acceptance checks.
   - Runtime/setup commands, environment variable names and credential sources (no secrets), durable artifacts, relevant running jobs, and agent/worktree ownership.
   - The next agent's first action and exact command(s).

   Commit the document separately after a successful WIP checkpoint; reference that code SHA rather than trying to embed the document's own SHA. If the WIP checkpoint failed, save the document without committing or disturbing the existing index. Record any uncommitted work and exclusions.

4. **Update the issue.** Re-check the issue is open, then post a handover comment with completed work, a prioritized remaining-work checklist, blockers, validation, branch/SHAs, document path, remote availability, and the first next action. Preserve the issue body and leave it open; edit its checklist only if specifically requested. Use a structured tool argument or `gh issue comment NUMBER --repo OWNER/REPO --body-file PATH` with literal Markdown. Check for an existing matching comment before retrying, read back the result, and capture its URL. Link the document at a commit only if pushed. If blocked, retain a ready-to-post draft in the handover and report the reason.

5. **Verify and report.** Check final status, commits, document, and issue comment. Account for remaining changes; never erase them to manufacture a clean tree. Reply briefly with commit SHAs, pushed/local-only status, document link, issue comment link or blocker, and the first next action. Do not claim unverified steps succeeded.
