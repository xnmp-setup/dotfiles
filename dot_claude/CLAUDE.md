## Personal Preferences
- Tone: Concise, technical, no filler.
- Style: Prefer functional programming patterns (immutability, pure functions, composition) where practical.

## Architecture & Design
- Write code that is easy to reason about, test, and refactor. Long term maintainability is the most important consideration. 
- Design domain logic first; separate it clearly from infrastructure and implementation details.
- Try to adhere to SOLID principles.
- When approaching a difficult problem, first research the industry standard approach to the problem and use it to guide your approach.

## Testing
- Unit tests must test behavior and contracts, not implementation details. Assert on outputs and observable side effects, not on how state is structured internally.
- Avoid tautological tests that just restate the implementation. 
- E2E tests must assert on actual feature outcomes, not just that a component rendered. Verify the user-visible result, not the intermediate state.
- Consider adding unit tests whenever new business logic is introduced. 
- Ensure that edge cases are covered - eg input is malformed, null, extremely large

## Workflow
- After you're done a long line of work (30+ minutes), if you're at 30%+ context, set a timer so that you write a handover document before 1 hr passes after finish and the cache expires, to save on LLM costs. If the user sends another message then cancel this timer. 
- When making high risk changes use an adversarial review subagent to verify findings. 
- Fable tokens are very expensive. When the main model is Fable, delegate work to Opus, Sonnet or Haiku subagents for less complex tasks (searching, reading, exploration, routine edits, test runs). Intervene if a subagent goes off track or is missing relevant context. Reserve Fable for high-level reasoning and synthesis, or for high-risk high-complexity tasks, or when the cost of re-explaining context outweighs the savings.
- Before fanning out multiple implementation subagents, write a short conventions brief (where new state lives, async/worker pattern to follow, shared helpers to reuse) and include it in every agent prompt. Fable owns changes to shared seams itself — core structs, hot-path signatures, cross-cutting patterns — since parallel agents extending shared code independently create consistency debt.
- Worktree agents may be created from a stale base commit. Instruct every worktree agent to verify `git merge-base HEAD <target-branch>` against the target's real tip before starting, and re-verify yourself before merging their branch.
- Nested subagents are fine when the parent consumes the child's result as a blocking tool result in the same turn. What deadlocks (likely harness bug, observed 2026-07): a parent launching background children then ending its turn to await their completion — notifications route to the main session, not the spawner, and the child can't SendMessage the parent by name. Until fixed, tell delegated agents to keep any child work blocking; stray nested reports land with the main session, which folds them in.

## Debugging
- Try to reproduce the bug before jumping to conclusions about its cause. 
- If the root cause of a bug is unclear, add targeted logging or instrumentation before modifying logic.
- When unsure, ask clarifying questions rather than guessing. 
- Fix root causes, not symptoms. Avoid band-aid fixes like stopPropagation to mask duplicate handlers, setTimeout to paper over race conditions, or flags to suppress unwanted side effects. If a fix feels like a workaround, step back and address the underlying design issue.
- Form and add logs to test all independent hypotheses at once, then run once and read combined output — don't add one log, run, observe, repeat. Go serial only on genuine dependencies.
- Isolate long debug loops in a subagent that returns the conclusion, not the full investigation transcript.

## Misc
- When testing whether hooks work, don't pipe text to the shell scripts. Instead run actual commands that would trigger the hooks.
