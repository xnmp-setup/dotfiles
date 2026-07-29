# RTK - Rust Token Killer

Bash commands are auto-rewritten to `rtk <cmd>` by a PreToolUse hook (transparent, 0 tokens).

**`rtk` reformats output** for cargo/git/npx/test-runners — it is not the native
format. If you intend to pipe output into your own `grep`/`awk`/`sed` pattern, run
`rtk proxy <cmd>` instead, or the pattern will silently match nothing.

`rtk` also decorates output (`(empty)`, `N matches in N files:`), so piping into
`wc -l` / `head` / `xargs` gives off-by-N results. Use `rtk proxy` when counting.

Do **not** prefix `rtk proxy` onto `uv`/`bun`/`bunx`/`sh`/`python3`/`cp` — rtk
never filters those.
