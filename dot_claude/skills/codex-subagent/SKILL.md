---
name: codex-subagent
description: Delegate a task to the OpenAI Codex CLI as a subagent and get its answer back. Use when the user asks for a second opinion from Codex/GPT, wants a task run by Codex, wants two models to review the same code, or says "ask codex". Also use for offloading open-ended web research, or when a fresh non-Claude perspective is wanted on a bug or design.
---

# Codex subagent

Runs `codex exec` (Codex CLI's non-interactive mode) as a one-shot subagent and
returns its final message. Useful for a second opinion from a different model
family, or for offloading a self-contained task — code or otherwise; with `-w`
it does open-ended web research.

## Usage

```bash
~/.claude/skills/codex-subagent/scripts/codex-run.sh [options] "<prompt>"
```

Options:

- `-m MODEL` — model override (e.g. `gpt-5.1-codex-max`). Omit for Codex's default.
- `-s SANDBOX` — `read-only` (default), `workspace-write`, `danger-full-access`.
- `-C DIR` — working root. Default `$PWD`; pass the repo root explicitly when it matters.
- `-t SECONDS` — timeout, default 900.
- `-w` — enable live web search. Off by default; required for any task needing
  current information from the internet.
- `-l FILE` — transcript log path. Default: `$TMPDIR/codex-run-<pid>.log`.
- `-f` — print the full transcript instead of just the final message.

Long prompts: write the prompt to a file in the scratchpad and pipe it in —
`scripts/codex-run.sh -C /repo < prompt.md` — rather than fighting shell quoting.

## Running it

**Always with `dangerouslyDisableSandbox: true`.** Codex writes session state
under `~/.codex`, which Claude Code's command sandbox denies — inside it, Codex
dies with `Read-only file system (os error 30)`. Codex applies its own sandbox to
whatever it executes, set by `-s`.

**Background anything non-trivial** (`run_in_background: true`). A web-research
run took ~17 minutes; even a trivial prompt takes ~20s of startup.

**Watch progress via the log, not the task output.** The script prints nothing
until Codex exits, so a backgrounded run's output file stays empty the whole
time — that is not a hang. The transcript is written live; tail it:

```bash
tail -c 2000 "$(ls -t "${TMPDIR:-/tmp}"/codex-run-*.log | head -1)"
```

`pgrep -af "codex exec"` confirms it is still alive.

## Choosing the sandbox

Default to `read-only`. That is right for review, analysis, research, and second
opinions, and it means Codex cannot touch the working tree.

Use `workspace-write` **only** when the user has asked for Codex to actually
make changes, and tell them before you do. Never use `danger-full-access`.

## Prompting the subagent

Codex starts with none of this conversation's context. The prompt must be
self-contained:

- State the repo-relative paths it should read; it can explore, but naming the
  entry points saves a lot of wall-clock.
- State the exact question and the shape of answer you want back (a verdict, a
  list of findings with file:line, a patch in a fenced block).
- Say what it must not do ("do not modify files", "do not run the test suite").
- For research: demand only what it actually found, forbid invented URLs and
  prices, and require it to say which sources blocked it. Codex complies with
  this and the resulting caveats are the most useful part of the answer.

For an adversarial review, do not hand over your own conclusions — describe the
change and ask for independent findings, so you get a fresh read rather than an
echo.

## Reporting back

Codex's output is a subagent result, not user-facing text and not authoritative.
Summarize what it found, say plainly that it came from Codex, and verify any
claim before acting on it. In one smoke test it confidently named a file that
does not exist. For web research, note that its results may come from a crawl
weeks or months old.

## Gotchas already handled in the script

Do not "fix" these back:

- `codex exec` has **no `--search` flag** — that is TUI-only. Web search is
  `-c tools.web_search=true`.
- Codex appends piped stdin to the prompt and **blocks forever on an open stdin
  pipe**, so the script always passes it `/dev/null`.
- An interactive shell may define `codex` as a **function**; the script unsets it
  and resolves the real binary, with nvm/homebrew/local fallbacks.

## Requirements

The `codex` CLI must be installed (`npm i -g @openai/codex`) and authenticated
(`codex login`). It is not managed by this repo. The script exits 127 with an
install hint when it is missing, so on a machine without Codex the skill fails
loudly instead of silently doing nothing.
