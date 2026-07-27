# Global agent instructions (mirrors ~/.claude/CLAUDE.md for codex sessions)

- Tone: concise, technical, no filler.
- Prefer functional patterns (immutability, pure functions, composition)
  where practical. Long-term maintainability is the top consideration;
  separate domain logic from infrastructure. SOLID where sensible.
- For hard problems, first check the industry-standard approach and let it
  guide the design.
- Python: use uv (never pip/pipenv/poetry). Type-check with pyrefly (not
  mypy/pyright).
- Tests assert behavior/contracts and observable outputs, not internal
  state; no tautological tests. Cover edge cases (malformed, null, huge).
  E2E tests must assert user-visible outcomes, not "component rendered".
- Debugging: reproduce before theorizing; add targeted instrumentation for
  ALL independent hypotheses in one pass, then run once. Fix root causes —
  no stopPropagation/setTimeout/flag band-aids over design problems.
- When unsure, ask rather than guess.
