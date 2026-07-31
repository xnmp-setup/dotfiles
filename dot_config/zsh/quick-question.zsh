# Fast one-off shell questions. Commands are only prefilled for review; this
# module never executes model-suggested commands.

typeset -g Q_MODEL="${Q_MODEL:-gpt-5.6-luna}"

typeset -g _Q_BASE_INSTRUCTIONS='You are a fast, read-only shell assistant for one-off questions.

- Do not call tools or inspect files. Answer only from the request and the environment context below.
- Use commands and package names native to the detected platform; do not assume a different operating system or distribution.'

typeset -g _Q_COMMAND_INSTRUCTIONS='Return exactly one executable Zsh command on one line and nothing else.
- Do not include a prefix, backticks, Markdown, explanation, alternatives, or comments.
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

_quick_command() {
  emulate -L zsh

  local query="$*"
  if [[ -z "$query" ]]; then
    print -u2 -- "usage: q <question>"
    return 2
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
