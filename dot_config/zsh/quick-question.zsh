# Fast one-off shell questions. Commands are only prefilled for review; this
# module never executes model-suggested commands. A bare `q` sends the current
# failure streak — commands, exit statuses, captured stderr — and prefills a fix.

typeset -g Q_MODEL="${Q_MODEL:-gpt-5.6-luna}"

# The Codex CLI spends ~2.4s per invocation on process startup and teardown and
# ships ~10k tokens of agent scaffolding we never use, so questions go straight
# to the same backend it talks to. Everything degrades to the CLI on any failure.
typeset -g Q_DIRECT="${Q_DIRECT:-1}"
typeset -g Q_AUTH_FILE="${Q_AUTH_FILE:-${CODEX_HOME:-$HOME/.codex}/auth.json}"
typeset -g Q_DIRECT_ENDPOINT="${Q_DIRECT_ENDPOINT:-https://chatgpt.com/backend-api/codex/responses}"
typeset -gi Q_DIRECT_TIMEOUT="${Q_DIRECT_TIMEOUT:-25}"

# Credentials are never written here; refreshing is always delegated to Codex.
typeset -gi _Q_TOKEN_MIN_LIFETIME=300    # skip the direct path below this
typeset -gi _Q_REFRESH_THRESHOLD=43200   # nudge Codex to renew below this
typeset -gi _Q_REFRESH_FORCE_BELOW=7200  # force a real request below this
typeset -gi _Q_REFRESH_INTERVAL=1800     # at most one nudge per this many seconds

typeset -g _Q_BASE_INSTRUCTIONS='You are a fast, read-only shell assistant for one-off questions.

- Do not call tools or inspect files. Answer only from the request and the environment context below.
- Use commands and package names native to the detected platform; do not assume a different operating system or distribution.'

typeset -g _Q_COMMAND_INSTRUCTIONS='Return exactly one executable Zsh command on one line, optionally followed by a short trailing Zsh comment.
- Format: <command>  # <explanation>
- Omit the comment when the command is self-explanatory to someone who knows the shell: a common command with obvious flags, or one whose name already states what it does.
- Add the comment only when it tells the reader something the command does not: cryptic flags, a non-obvious pipeline, a surprising choice of tool, or a side effect worth noticing.
- When present, keep the explanation to one clause, under about twelve words, on the same line.
- Do not include a prefix, backticks, Markdown, alternatives, or any prose outside that trailing comment.
- Do not execute the command; the shell will prefill it for the user to review.
- For a factual question, return a command that prints the answer.
- If the request is ambiguous, choose the safest useful command rather than asking a question.'

typeset -g _Q_ANSWER_INSTRUCTIONS='Answer the question fully in plain text suitable for a terminal.
- Include explanations, caveats, and commands when useful.
- If the context is insufficient, say so instead of inventing details.
- Do not follow the command-only response contract.'

_q_is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  [[ -r /proc/sys/kernel/osrelease ]] || return 1

  local kernel_release="$(</proc/sys/kernel/osrelease)"
  [[ "${kernel_release:l}" == *microsoft* ]]
}

_q_os_context() {
  emulate -L zsh

  local kernel="$(uname -s)"
  if [[ "$kernel" == Darwin ]]; then
    print -r -- "macOS"
    return
  fi

  local os="$kernel"
  if [[ -r /etc/os-release ]]; then
    local key value pretty_name='' distribution_id=''
    while IFS='=' read -r key value; do
      case "$key" in
        PRETTY_NAME) pretty_name="${(Q)value}" ;;
        ID) distribution_id="${(Q)value}" ;;
      esac
    done < /etc/os-release
    os="${pretty_name:-${distribution_id:-$kernel}}"
  fi

  if _q_is_wsl; then
    os+=" under Windows WSL"
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && os+=" ($WSL_DISTRO_NAME)"
  fi

  print -r -- "$os"
}

_q_package_context() {
  emulate -L zsh

  local -a managers=()
  command -v pacman >/dev/null 2>&1 && managers+=("pacman")
  command -v yay >/dev/null 2>&1 && managers+=("yay (AUR)")
  command -v nix >/dev/null 2>&1 && managers+=("Nix")
  command -v nixos-rebuild >/dev/null 2>&1 && managers+=("nixos-rebuild")
  command -v home-manager >/dev/null 2>&1 && managers+=("Home Manager")
  command -v brew >/dev/null 2>&1 && managers+=("Homebrew")
  command -v apt-get >/dev/null 2>&1 && managers+=("apt")

  if (( $#managers )); then
    print -r -- "${(j:, :)managers}"
  else
    print -r -- "not detected"
  fi
}

_q_service_context() {
  emulate -L zsh

  if [[ "$(uname -s)" == Darwin ]] && command -v launchctl >/dev/null 2>&1; then
    print -r -- "launchd/launchctl"
  elif [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    print -r -- "systemd/systemctl"
  else
    print -r -- "not detected"
  fi
}

_q_desktop_context() {
  emulate -L zsh

  if [[ "$(uname -s)" == Darwin ]]; then
    print -r -- "macOS"
  elif _q_is_wsl; then
    print -r -- "Windows host via WSL"
  elif [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    print -r -- "Hyprland${XDG_SESSION_TYPE:+ ($XDG_SESSION_TYPE)}"
  else
    print -r -- "${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-not detected}}${XDG_SESSION_TYPE:+ ($XDG_SESSION_TYPE)}"
  fi
}

_q_terminal_context() {
  emulate -L zsh

  if [[ -n "${TERM_PROGRAM:-}" ]]; then
    print -r -- "$TERM_PROGRAM"
  elif [[ -n "${WEZTERM_PANE:-}" ]]; then
    print -r -- "WezTerm"
  else
    print -r -- "${TERM:-not detected}"
  fi
}

_q_environment_context() {
  print -r -- "Environment:
- OS: $(_q_os_context)
- Interactive shell: Zsh
- Desktop/session: $(_q_desktop_context)
- Terminal: $(_q_terminal_context)
- Dotfiles: managed with chezmoi and shared across machines
- Available package managers: $(_q_package_context)
- Service manager: $(_q_service_context)
- Current working directory: $PWD"
}

_q_full_instructions() {
  local mode="$1"
  local response_instructions
  case "$mode" in
    command) response_instructions="$_Q_COMMAND_INSTRUCTIONS" ;;
    answer) response_instructions="$_Q_ANSWER_INSTRUCTIONS" ;;
    *) return 2 ;;
  esac

  print -r -- "$_Q_BASE_INSTRUCTIONS

$response_instructions

$(_q_environment_context)"
}

# Emits access token, account id, and token expiry as three lines, or fails if
# the credential is missing, unreadable, or not a ChatGPT-mode token.
_q_auth_fields() {
  emulate -L zsh

  [[ -r "$Q_AUTH_FILE" ]] || return 1

  command jq -er '
    def b64url_decode:
      gsub("-"; "+") | gsub("_"; "/")
      | . + ("=" * ((4 - (length % 4)) % 4))
      | @base64d;

    (.tokens.access_token // "") as $token
    | (.tokens.account_id // "") as $account
    | select($token != "" and $account != "")
    | ($token | split(".") | .[1] | b64url_decode | fromjson | .exp) as $expiry
    | [$token, $account, ($expiry | tostring)] | join("\n")
  ' "$Q_AUTH_FILE" 2>/dev/null
}

_q_now() {
  command date +%s
}

_q_session_id() {
  emulate -L zsh

  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    print -r -- "$(</proc/sys/kernel/random/uuid)"
  elif (( $+commands[uuidgen] )); then
    command uuidgen
  else
    printf '%08x-%04x-4%03x-8%03x-%012x\n' \
      $RANDOM$RANDOM $RANDOM $RANDOM $RANDOM $RANDOM$RANDOM
  fi
}

# Reads the streamed response and stops at the completed message, so the tail of
# the stream and the connection teardown stay off the critical path. Takes the
# jq filter that turns the completed message into the answer, so each mode
# decides its own response shape.
_q_read_stream() {
  emulate -L zsh

  local extract="${1:-.text // empty}"
  local line payload text
  while IFS= read -r line; do
    [[ "$line" == 'data: '* ]] || continue

    payload="${line#data: }"
    [[ "$payload" == *'"response.output_text.done"'* ]] || continue

    text="$(printf '%s' "$payload" | command jq -r "$extract" 2>/dev/null)"
    [[ -n "$text" ]] || continue

    print -r -- "$text"
    return 0
  done

  return 1
}

# Command mode constrains decoding to a schema. Without it the model trails
# junk tokens onto short answers ("ls -lS" + garbage) at low reasoning effort;
# the schema removes that failure and keeps the cheaper effort setting.
# The explanation is a separate field rather than part of the command string so
# the model cannot smuggle a multi-line rationale into the prefilled line. Strict
# decoding requires every property, so "omitted" is the empty string rather than
# a missing key; the extract filter drops the comment when it comes back empty.
typeset -g _Q_COMMAND_FORMAT='{
  "type": "json_schema",
  "name": "shell_command",
  "strict": true,
  "schema": {
    "type": "object",
    "properties": {
      "command": { "type": "string" },
      "explanation": {
        "type": "string",
        "description": "Short clause explaining the command, or the empty string when it is self-explanatory."
      }
    },
    "required": ["command", "explanation"],
    "additionalProperties": false
  }
}'

_q_direct() {
  emulate -L zsh

  [[ "$Q_DIRECT" == 1 ]] || return 1
  (( $+commands[curl] && $+commands[jq] )) || return 1

  local -a fields
  fields=("${(@f)$(_q_auth_fields)}")
  (( $#fields == 3 )) || return 1

  local token="$fields[1]" account="$fields[2]"
  local -i expiry="$fields[3]"
  (( expiry - $(_q_now) > _Q_TOKEN_MIN_LIFETIME )) || return 1

  local mode="$1"
  local verbosity effort format extract
  case "$mode" in
    command)
      # Benchmarked none/low/medium/high/xhigh: none averages 1.2s against low's
      # 1.7s and medium's 2.6s, and avoids a reasoning spiral that made medium
      # exceed 60s on some questions. The schema keeps output clean at any
      # effort, so there is nothing to buy by reasoning harder here.
      verbosity=low effort=none format="$_Q_COMMAND_FORMAT"
      # Rejoins the two fields into one prefillable line. The explanation is
      # flattened and de-duplicated of any leading "#" the model adds itself.
      extract='.text | fromjson
        | (.command | sub("\\s+$"; "")) as $command
        | (.explanation // ""
           | gsub("[\r\n\t]+"; " ")
           | sub("^\\s+"; "") | sub("\\s+$"; "")
           | sub("^#\\s*"; "")) as $explanation
        | if $command == "" then empty
          elif $explanation == "" then $command
          else $command + "  # " + $explanation
          end'
      ;;
    answer)
      # Same reasoning as command mode: none is the fastest setting and avoids
      # the reasoning spirals higher effort showed on one-off questions.
      verbosity=medium effort=none format='{ "type": "text" }'
      extract='.text // empty'
      ;;
    *) return 2 ;;
  esac

  local instructions payload
  instructions="$(_q_full_instructions "$mode")" || return 1
  payload="$(
    command jq -nc \
      --arg model "$Q_MODEL" \
      --arg instructions "$instructions" \
      --arg query "$2" \
      --arg verbosity "$verbosity" \
      --arg effort "$effort" \
      --argjson format "$format" \
      '{
        model: $model,
        instructions: $instructions,
        input: [{
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: $query }]
        }],
        stream: true,
        store: false,
        reasoning: { effort: $effort },
        text: { verbosity: $verbosity, format: $format }
      }'
  )" || return 1

  command curl -s --max-time "$Q_DIRECT_TIMEOUT" \
    -X POST "$Q_DIRECT_ENDPOINT" \
    -H "Authorization: Bearer $token" \
    -H "chatgpt-account-id: $account" \
    -H "originator: codex_cli_rs" \
    -H "session_id: $(_q_session_id)" \
    -H "content-type: application/json" \
    -H "accept: text/event-stream" \
    --data-binary "$payload" 2>/dev/null |
    _q_read_stream "$extract"
}

# Codex renews the credential as a side effect of its own authenticated calls,
# so a stale token is repaired by using Codex rather than by rewriting the file.
_q_renew_credential() {
  emulate -L zsh

  (( $+commands[codex] )) || return 1
  command codex debug models >/dev/null 2>&1

  local -a fields
  fields=("${(@f)$(_q_auth_fields)}")
  (( $#fields == 3 )) || return 1

  local -i expiry="$fields[3]"
  (( expiry - $(_q_now) > _Q_REFRESH_FORCE_BELOW )) && return 0

  command codex -a never exec \
    --ignore-user-config \
    --model "$Q_MODEL" \
    --sandbox read-only \
    --ephemeral \
    --skip-git-repo-check \
    --cd /tmp \
    --color never \
    -c 'model_reasoning_effort="low"' \
    -c 'model_verbosity="low"' \
    ping </dev/null >/dev/null 2>&1
}

# Renews well before expiry, detached and rate limited, so the user never waits
# on it. If it never runs, an expired token still just falls back to Codex.
_q_schedule_renewal() {
  emulate -L zsh

  local -a fields
  fields=("${(@f)$(_q_auth_fields)}")
  (( $#fields == 3 )) || return 0

  local -i expiry="$fields[3]"
  local -i now=$(_q_now)
  (( expiry - now < _Q_REFRESH_THRESHOLD )) || return 0

  local stamp="${XDG_CACHE_HOME:-$HOME/.cache}/quick-question/renewal"
  command mkdir -p "${stamp:h}" 2>/dev/null || return 0

  if [[ -f "$stamp" ]]; then
    local -i last=$(command date -r "$stamp" +%s 2>/dev/null || print -r -- 0)
    (( now - last < _Q_REFRESH_INTERVAL )) && return 0
  fi
  command touch "$stamp" 2>/dev/null

  _q_renew_credential >/dev/null 2>&1 &!
}

_q_luna_available() {
  command -v codex >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  command codex debug models 2>/dev/null |
    command jq -e --arg model "$Q_MODEL" \
      'any(.models[]?; .slug == $model and .visibility != "hide")' \
      >/dev/null 2>&1
}

_q_codex() {
  emulate -L zsh

  local mode="$1"
  local verbosity=low
  [[ "$mode" == answer ]] && verbosity=medium

  local instructions encoded_instructions
  instructions="$(_q_full_instructions "$1")" || return
  encoded_instructions="$(
    command jq -Rn --arg value "$instructions" '$value'
  )" || return 1

  command codex -a never exec \
    --ignore-user-config \
    --model "$Q_MODEL" \
    --sandbox read-only \
    --ephemeral \
    --skip-git-repo-check \
    --cd /tmp \
    --color never \
    -c 'model_reasoning_effort="low"' \
    -c "model_verbosity=\"$verbosity\"" \
    -c "developer_instructions=$encoded_instructions" \
    "$2" </dev/null 2>/dev/null
}

_q_haiku_fallback() {
  (( $+functions[_anthropic_haiku] )) || return 1

  local mode="$1"
  local max_tokens=256
  [[ "$mode" == answer ]] && max_tokens=1024

  _anthropic_haiku "$(_q_full_instructions "$mode")

Request: $2" "$max_tokens"
}

_q_ask() {
  emulate -L zsh

  local mode="$1"
  local query="$2"
  local response

  if response="$(_q_direct "$mode" "$query")" && [[ -n "$response" ]]; then
    print -r -- "$response"
    _q_schedule_renewal
    return
  fi

  if _q_luna_available &&
    response="$(_q_codex "$mode" "$query")" &&
    [[ -n "$response" ]]
  then
    print -r -- "$response"
    return
  fi

  print -u2 -- "q: $Q_MODEL unavailable; falling back to Haiku"
  response="$(_q_haiku_fallback "$mode" "$query")" || {
    print -u2 -- "q: no working question backend"
    return 1
  }

  [[ -n "$response" ]] || {
    print -u2 -- "q: Haiku returned no response"
    return 1
  }

  print -r -- "$response"
}

_q_prefill_command() {
  emulate -L zsh
  setopt extended_glob

  local cmd="${1#CMD:}"
  cmd="${cmd##[[:space:]]#}"
  cmd="${cmd%%[[:space:]]#}"
  cmd="${cmd#\`}"
  cmd="${cmd%\`}"

  if [[ -z "$cmd" || "$cmd" == *$'\n'* ]]; then
    print -u2 -- "q: model did not return exactly one command; nothing queued"
    return 1
  fi

  print -z -- "$cmd"
}

# --- Failed-command tracking (powers a bare `q`) ---
# Holds the consecutive failures immediately before the current prompt — a
# success empties it. Session-local, never persisted. Declared without an
# initializer so re-sourcing this file keeps the recorded streak.
typeset -ga _Q_FAILURES
typeset -gi _Q_MAX_FAILURES="${Q_MAX_FAILURES:-5}"
typeset -g _q_last_command=''

# Error output can only be captured while the command runs, so stderr is
# mirrored through tee into a per-session file. Cost: for the command's
# lifetime stderr is a pipe, not a tty, so tools that gate progress bars on
# isatty(stderr) (git clone, curl) go quiet. Q_CAPTURE_STDERR=0 turns the
# mirror off; the streak then records commands and exit statuses only.
typeset -g Q_CAPTURE_STDERR="${Q_CAPTURE_STDERR:-1}"
typeset -g _Q_STDERR_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/quick-question/stderr-$$"
typeset -gi _q_stderr_fd=0

# For sub-second sleeps in the flush wait; degrades to `command sleep` below.
zmodload zsh/zselect 2>/dev/null

_q_capture_command() {
  _q_last_command="$1"

  [[ "$Q_CAPTURE_STDERR" == 1 ]] && (( $+commands[tee] )) || return 0
  [[ -d "${_Q_STDERR_FILE:h}" ]] || command mkdir -p -- "${_Q_STDERR_FILE:h}" 2>/dev/null || return 0
  command rm -f -- "$_Q_STDERR_FILE.done" 2>/dev/null

  # Two statements: the tee redirection references the fd the first one opens.
  # The .done flag marks tee's flush as complete; zsh does not put the process
  # substitution's pid in $!, so completion is signalled through the filesystem.
  exec {_q_stderr_fd}>&2 || return 0
  exec 2> >(command tee -- "$_Q_STDERR_FILE" >&$_q_stderr_fd; : >| "$_Q_STDERR_FILE.done")
}

_q_restore_stderr() {
  (( _q_stderr_fd )) || return 0
  exec 2>&$_q_stderr_fd {_q_stderr_fd}>&-
  _q_stderr_fd=0
}

# Tail of the captured stderr, ANSI escapes stripped, empty when nothing was
# captured (mirror off, tee missing, or the command wrote nothing). Runs only
# on the failure path, after _q_restore_stderr has closed the shell's end of
# the pipe, so tee normally exits within a scheduling quantum. The wait is
# bounded because a background job holding the mirrored fd keeps tee alive
# indefinitely, and this must never hang the prompt.
_q_failure_output() {
  emulate -L zsh
  setopt extended_glob

  local -i tries=5
  while (( tries-- )) && [[ ! -e "$_Q_STDERR_FILE.done" ]]; do
    if (( $+builtins[zselect] )); then
      zselect -t 1   # centiseconds
    else
      command sleep 0.01
    fi
  done

  [[ -s "$_Q_STDERR_FILE" ]] || return 0
  local out="$(command tail -c 2048 -- "$_Q_STDERR_FILE" 2>/dev/null)"
  out="${out//$'\e'\[[0-9;]#[[:alpha:]]/}"
  out="${out//$'\r'/}"
  print -r -- "$out"
}

_q_cleanup_stderr_file() {
  command rm -f -- "$_Q_STDERR_FILE" "$_Q_STDERR_FILE.done" 2>/dev/null
}

# Runs first in precmd (prepended below) so $? is still the command's own
# status, and returns that status unchanged so later hooks (p10k's status
# segment) still see it.
_q_record_failure() {
  local -i code=$?
  local cmd="$_q_last_command"
  _q_last_command=''
  _q_restore_stderr

  # Only the streak of failures leading up to the current prompt is kept: any
  # successful command resets the buffer. 130/148 are Ctrl-C and Ctrl-Z — user
  # interruptions, neither failure nor success. `q`/`qq` are meta and skipped:
  # they succeed (the answer arrives as a prefilled command), and that success
  # must not erase the streak `q` exists to fix before the fix has been run.
  if [[ -n "$cmd" ]] \
    && [[ "$cmd" != (q|qq) && "$cmd" != (q|qq)[[:space:]]* ]]; then
    if (( code == 0 )); then
      _Q_FAILURES=()
    elif (( code != 130 && code != 148 )); then
      local entry="\$ $cmd"$'\n'"exit $code"
      local output="$(_q_failure_output)"
      [[ -n "$output" ]] && entry+=$'\n'"$output"
      _Q_FAILURES+=("$entry")
      (( $#_Q_FAILURES > _Q_MAX_FAILURES )) && shift _Q_FAILURES
    fi
  fi

  return code
}

_q_fix_last_failure() {
  emulate -L zsh

  if (( ! $#_Q_FAILURES )); then
    print -u2 -- "q: no failed commands since the last success"
    return 1
  fi

  # No replay: the failures are already on the user's screen just above.
  local query="These Zsh commands all failed in a row, oldest first — my consecutive attempts at the same goal. Each entry is the command (after \$), its exit status, and the error output it printed, when captured:

${(pj:\n\n:)_Q_FAILURES}

Return a corrected version of the most recent failed command that should succeed. Use the earlier failures only as context for what I am trying to do."

  local response
  response="$(_q_ask command "$query")" || return
  _q_prefill_command "$response"
}

_quick_command() {
  emulate -L zsh

  local query="$*"
  if [[ -z "$query" ]]; then
    _q_fix_last_failure
    return
  fi

  local response
  response="$(_q_ask command "$query")" || return
  _q_prefill_command "$response"
}

_quick_answer() {
  emulate -L zsh

  local query="$*"
  if [[ -z "$query" ]]; then
    print -u2 -- "usage: qq <question>"
    return 2
  fi

  _q_ask answer "$query"
}

alias q='_quick_command'
alias qq='_quick_answer'

# preexec order doesn't matter; precmd must run before anything that clobbers
# $? (p10k is sourced earlier and appends), so prepend rather than add-zsh-hook.
autoload -Uz add-zsh-hook
add-zsh-hook preexec _q_capture_command
add-zsh-hook zshexit _q_cleanup_stderr_file
precmd_functions=(_q_record_failure ${precmd_functions:#_q_record_failure})
