---
paths:
  - "**/*.tsx"
  - "**/*.jsx"
---

Avoid `useEffect` when the same result can be achieved without it. Prefer event handlers, `useMemo`, `useSyncExternalStore`, or computing values during render. `useEffect` is a last resort for genuine side effects (subscriptions, DOM manipulation, external system synchronisation). Never use `useEffect` to synchronise state — derive it instead.
