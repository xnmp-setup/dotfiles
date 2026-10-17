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
  -t SECONDS    hard wall-clock ceiling (default: 7200)
  -i SECONDS    idle timeout: kill when the transcript has not grown for this
                long (default: 1200). Codex logs a shell command only when it
                finishes, so this must exceed the longest command it runs
                (e.g. a full test suite).
  -w            enable live web search (Codex's native web_search tool)
  -f            full output: stream the whole transcript instead of only the
                final message
  -l FILE       transcript log path (default: a codex-run-*.log under $TMPDIR).
                Written live, so a backgrounded run can be tailed for progress.
  -S DIR        enable live messages via app-server; create a private control
                directory (must not already exist). Requires Python 3.
                Send with: codex-send.py DIR "additional instructions"

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
timeout_s=7200
idle_s=1200
full=0
search=0
logfile=""
control=""

while getopts ":m:e:s:C:t:i:l:S:wfh" opt; do
  case "$opt" in
    m) model="$OPTARG" ;;
    e) effort="$OPTARG" ;;
    s) sandbox="$OPTARG" ;;
    C) workdir="$OPTARG" ;;
    t) timeout_s="$OPTARG" ;;
    i) idle_s="$OPTARG" ;;
    l) logfile="$OPTARG" ;;
    S) control="$OPTARG" ;;
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

# Watchdog in plain bash rather than GNU `timeout`, which macOS lacks. A
# wall-clock cap alone killed productive runs mid-way through their final test
# suite, so the primary guard is idleness (no transcript growth); the hard
# ceiling only backstops a run that keeps logging without finishing.
# Codex starts each shell command in its own session, so a process-group kill
# misses them; walk the tree instead (pgrep -P works on Linux and macOS).
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    descendants "$child"
    echo "$child"
  done
}
kill_tree() {
  local pids
  pids="$(descendants "$codex_pid") $codex_pid"
  kill -TERM $pids 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do kill -0 "$codex_pid" 2>/dev/null || break; sleep 5; done
  kill -KILL $pids 2>/dev/null || true
}

if [ -n "$control" ]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "error: live messages (-S) require Python 3" >&2
    exit 127
  }
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  # Keep the exec path unchanged for callers that do not need live messages.
  live_args=(--codex "$codex_bin" --control "$control" --output "$last_msg"
    --workdir "$workdir" --sandbox "$sandbox")
  [ -n "$model" ] && live_args+=(--model "$model")
  [ -n "$effort" ] && live_args+=(--effort "$effort")
  [ "$search" -eq 1 ] && live_args+=(--search)
  echo "codex control: $control" >&2
  python3 "$script_dir/codex-live.py" "${live_args[@]}" -- "$prompt" </dev/null >"$logfile" 2>&1 &
else
  "$codex_bin" "${args[@]}" -o "$last_msg" -- "$prompt" </dev/null >"$logfile" 2>&1 &
fi
codex_pid=$!

started=$SECONDS
last_growth=$SECONDS
last_size=0
reason=""
while kill -0 "$codex_pid" 2>/dev/null; do
  sleep 5
  size=$(wc -c <"$logfile" 2>/dev/null | tr -d ' ')
  if [ "${size:-0}" != "$last_size" ]; then
    last_size=${size:-0}
    last_growth=$SECONDS
  fi
  if [ $((SECONDS - started)) -ge "$timeout_s" ]; then
    reason="hit the ${timeout_s}s hard ceiling"
  elif [ $((SECONDS - last_growth)) -ge "$idle_s" ]; then
    reason="was idle (no transcript output) for ${idle_s}s"
  fi
  if [ -n "$reason" ]; then
    kill_tree
    break
  fi
done

status=0
wait "$codex_pid" || status=$?

if [ -n "$reason" ]; then
  echo "error: codex $reason" >&2
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
