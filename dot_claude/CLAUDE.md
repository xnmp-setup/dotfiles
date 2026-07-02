## Personal Preferences
- Tone: Concise, technical, no filler.
- Style: Prefer functional programming patterns (immutability, pure functions, composition) where practical.

## Architecture & Design
- Design domain logic first; separate it clearly from infrastructure and implementation details.
- Build small, composable abstractions with a bias toward readability and long-term maintainability.
- Adhere to SOLID principles; avoid premature generalization.
- Optimize for clarity over cleverness.
- When approaching a difficult problem, first research the industry standard approach to the problem and use it to guide your approach.

## Coding Standards
- Write code that is easy to reason about, test, and refactor.
- Favor explicit types, clear naming, and minimal side effects.
- Avoid unnecessary abstractions, frameworks, or indirection.

## Testing
- Unit tests must test behavior and contracts, not implementation details. Assert on outputs and observable side effects, not on how state is structured internally.
- Avoid tautological tests that just restate the implementation. 
- E2E tests must assert on actual feature outcomes, not just that a component rendered. Verify the user-visible result, not the intermediate state.
- Consider adding unit tests whenever new business logic is introduced. 
- Ensure that edge cases are covered - eg input is malformed, null, extremely large

## Workflow & Debugging
- Do not change behavior without understanding the cause.
- If the root cause of a bug is unclear, add targeted logging or instrumentation before modifying logic.
- Make incremental, verifiable changes; prefer small diffs.
- When unsure, ask clarifying questions rather than guessing.
- Fix root causes, not symptoms. Avoid band-aid fixes like stopPropagation to mask duplicate handlers, setTimeout to paper over race conditions, or flags to suppress unwanted side effects. If a fix feels like a workaround, step back and address the underlying design issue.

## Cost & Delegation
- Fable tokens are very expensive. When the main model is Fable, delegate work to Sonnet or Haiku subagents wherever possible (searching, reading, exploration, routine edits, test runs). Reserve Fable for the high-level reasoning and synthesis that actually needs it.

## Misc
- When testing whether hooks work, don't pipe text to the shell scripts. Instead run actual commands that would trigger the hooks.

@RTK.md
