#!/usr/bin/env bash
# Run a Codex CLI agent non-interactively and print only its final message.
#
# External dependency: the `codex` CLI (npm `@openai/codex`), authenticated via
# `codex login`. Installed separately, not by this skill. If it is absent the
# script exits 127 with a clear message rather than failing obscurely.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: codex-run.sh [options] <prompt>
       <prompt on stdin> | codex-run.sh [options]

Options:
  -m MODEL      model to use, e.g. gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna
                (default: codex's configured default; run `codex` interactively
                and use /model to see what your account offers)
  -e EFFORT     reasoning effort: minimal | low | medium | high | xhigh
                (default: codex's configured default). Higher effort thinks
                longer and costs more; use high/xhigh for hard review or
                research tasks, minimal/low for quick mechanical ones.
                Not every model supports every level; check with /model.
  -s SANDBOX    read-only | workspace-write | danger-full-access
                (default: read-only). Governs what Codex may touch locally.
  -C DIR        working root for the agent (default: $PWD)
  -t SECONDS    wall-clock timeout (default: 900)
  -w            enable live web search (Codex's native web_search tool)
  -f            full output: stream the whole transcript instead of only the
                final message
  -l FILE       transcript log path (default: a codex-run-*.log under $TMPDIR).
                Written live, so a backgrounded run can be tailed for progress.

Examples:
  codex-run.sh "Summarize what src/auth/ does."
  codex-run.sh -m gpt-5.6-sol -e xhigh -C /path/to/repo "Review the diff on this branch for correctness bugs."
  codex-run.sh -w -t 1800 "Research current best practice for X; cite sources."
EOF
}

# An interactive shell may define `codex` as a function; we want the binary.
unset -f codex 2>/dev/null || true

resolve_codex() {
  local c
  c=$(command -v codex 2>/dev/null || true)
  [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  local cand
  for cand in \
    "$HOME"/.nvm/versions/node/*/bin/codex \
    "$HOME"/.local/bin/codex \
    "$HOME"/.bun/bin/codex \
    /opt/homebrew/bin/codex \
    /usr/local/bin/codex; do
    [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

model=""
effort=""
sandbox="read-only"
workdir="$PWD"
timeout_s=900
full=0
search=0
logfile=""

while getopts ":m:e:s:C:t:l:wfh" opt; do
  case "$opt" in
    m) model="$OPTARG" ;;
    e) effort="$OPTARG" ;;
    s) sandbox="$OPTARG" ;;
    C) workdir="$OPTARG" ;;
    t) timeout_s="$OPTARG" ;;
    l) logfile="$OPTARG" ;;
    w) search=1 ;;
    f) full=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

case "$effort" in
  ""|minimal|low|medium|high|xhigh) ;;
  *)
    echo "error: invalid -e effort '$effort' (expected: minimal | low | medium | high | xhigh)" >&2
    exit 2
    ;;
esac

case "$sandbox" in
  read-only|workspace-write|danger-full-access) ;;
  *)
    echo "error: invalid -s sandbox '$sandbox' (expected: read-only | workspace-write | danger-full-access)" >&2
    exit 2
    ;;
esac

prompt="${*:-}"
if [ -z "$prompt" ]; then
  if [ -t 0 ]; then
    echo "error: no prompt given (as argument or on stdin)" >&2
    usage >&2
    exit 2
  fi
  prompt="$(cat)"
fi
# The prompt is fully in hand either way. Codex appends any piped stdin to the
# prompt as a <stdin> block, and blocks waiting for EOF when stdin is a pipe
# that nobody closes — so always hand it /dev/null below.

codex_bin=$(resolve_codex) || {
  echo "error: codex CLI not found. Install with: npm i -g @openai/codex, then run: codex login" >&2
  exit 127
}

args=(exec --color never --skip-git-repo-check -C "$workdir" -s "$sandbox")
[ -n "$model" ] && args+=(-m "$model")
# `codex exec` has no dedicated effort flag; the config override is the knob.
[ -n "$effort" ] && args+=(-c "model_reasoning_effort=\"$effort\"")
# `codex exec` has no --search flag (that is TUI-only); the config override is
# the equivalent. Server-side tool, so it works regardless of the -s sandbox,
# which governs only the shell commands Codex runs locally.
[ "$search" -eq 1 ] && args+=(-c tools.web_search=true)

last_msg=$(mktemp -t codex-last-XXXXXX)
trap 'rm -f "$last_msg"' EXIT

# The transcript is written live and deliberately kept: this script prints
# nothing until Codex finishes, and a caller that backgrounds it (or pipes it
# through `tail`) sees no progress at all until then. The log is the only
# progress signal, so it must be a real path the caller can tail.
: "${logfile:=${TMPDIR:-/tmp}/codex-run-$$.log}"
: >"$logfile"
echo "codex transcript: $logfile" >&2

status=0
timeout "${timeout_s}" "$codex_bin" "${args[@]}" -o "$last_msg" -- "$prompt" \
  </dev/null >"$logfile" 2>&1 || status=$?

if [ "$status" -eq 124 ]; then
  echo "error: codex timed out after ${timeout_s}s" >&2
  tail -n 40 "$logfile" >&2
  exit 124
fi

if [ "$full" -eq 1 ]; then
  cat "$logfile"
elif [ -s "$last_msg" ]; then
  cat "$last_msg"
else
  # No final message captured — surface the transcript so the failure is visible.
  cat "$logfile"
fi

exit "$status"
