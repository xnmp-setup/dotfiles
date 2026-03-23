---
paths:
  - "**/*.svelte"
  - "**/*.svelte.ts"
---

Avoid `$effect` when the same result can be achieved with Svelte 5's built-in reactivity (`$derived`, `$derived.by`, reactive assignments, template expressions). `$effect` is a last resort for genuine side effects (DOM manipulation, external subscriptions, logging). Never use `$effect` to synchronise state — use `$derived` instead.
