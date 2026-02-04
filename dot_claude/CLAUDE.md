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

## Workflow & Debugging
- Do not change behavior without understanding the cause.
- If the root cause of a bug is unclear, add targeted logging or instrumentation before modifying logic.
- Make incremental, verifiable changes; prefer small diffs.
- When unsure, ask clarifying questions rather than guessing.

