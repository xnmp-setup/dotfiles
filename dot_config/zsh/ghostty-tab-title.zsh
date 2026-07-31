[[ $TERM_PROGRAM == ghostty ]] || return 0

# Ghostty has no WezTerm-style format-tab-title callback, so keep the animator
# in the originating shell and let Claude/Codex hooks update its private state
# file. OSC 2 changes the title; OSC 9;4 adds native progress/error feedback.
zmodload zsh/zselect
autoload -Uz add-zsh-hook

__ghostty_set_tab_title() {
  local title=${1//$'\e'/}
  title=${title//$'\a'/}
  printf '\e]2;%s\e\\' "$title"
}

# Mirror WezTerm's foreground-app markers. These are Hack Nerd Font private-use
# glyphs; Ghostty/Pango resolves them through the installed system font fallback.
typeset -gA __ghostty_app_icons=(
  # editors
  micro             $'\ueae9'
  nano              $'\ueae9'
  vim               $'\ue62b'
  nvim              $'\ue62b'
  vi                $'\ue62b'
  hx                $'\uf0e7'
  helix             $'\uf0e7'
  emacs             $'\ue632'
  # git / version control
  keifu             $'\ue725'
  gg                $'\ue725'
  git               $'\ue702'
  lazygit           $'\ue702'
  gitui             $'\ue702'
  tig               $'\ue702'
  # file managers
  yazi              $'\uea83'
  ranger            $'\uea83'
  nnn               $'\uea83'
  lf                $'\uea83'
  broot             $'\uea83'
  # multiplexers / sessions
  zellij            $'\uf489'
  tmux              $'\uebc7'
  screen            $'\uebc7'
  # containers / infrastructure
  docker            $'\uf308'
  docker-compose    $'\uf308'
  kubectl           $'\U000f10fe'
  k9s               $'\U000f10fe'
  # languages / runtimes
  cargo             $'\ue7a8'
  rustc             $'\ue7a8'
  bun               $'\ue76f'
  node              $'\ue718'
  deno              $'\ue718'
  python            $'\ue606'
  uv                $'\ue606'
  go                $'\ue626'
  ruby              $'\ue739'
  lua               $'\ue620'
  # AI CLIs without a running agent animation
  openclaw          $'\U000f0ea0'
  # remote / network
  ssh               $'\U000f08c0'
  mosh              $'\U000f08c0'
  ping              $'\U000f0200'
  curl              $'\uf0ee'
  wget              $'\uf0ee'
  # monitors
  htop              $'\uf0e4'
  btop              $'\uf0e4'
  top               $'\uf0e4'
  btm               $'\uf0e4'
  # common tools
  fzf               $'\uf422'
  rg                $'\uf422'
  make              $'\ue673'
  bat               $'\uf0e7'
  less              $'\uf15c'
  man               $'\uf02d'
  brew              $'\uf0f4'
  psql              $'\ue76e'
  redis             $'\ue76d'
  sqlite3           $'\ue7c4'
)

# Resolve the first executable from a zsh command line without executing it.
# Handle the command modifiers and privilege/environment wrappers used commonly
# in interactive shells; unknown commands deliberately retain the shell marker.
__ghostty_command_name() {
  emulate -L zsh
  setopt local_options extended_glob

  local command_line=$1
  local token
  local -a words
  integer index=1

  words=(${(z)command_line}) 2>/dev/null || {
    REPLY=
    return 1
  }

  while (( index <= $#words )); do
    token=${(Q)words[$index]}

    if [[ $token == [A-Za-z_][A-Za-z0-9_]#=* ]]; then
      (( index++ ))
      continue
    fi

    case $token in
      command|exec|noglob|nocorrect|time|builtin)
        (( index++ ))
        continue
        ;;
      env)
        (( index++ ))
        while (( index <= $#words )); do
          token=${(Q)words[$index]}
          if [[ $token == -- ]]; then
            (( index++ ))
            break
          fi
          [[ $token == -* || $token == [A-Za-z_][A-Za-z0-9_]#=* ]] || break
          (( index++ ))
        done
        continue
        ;;
      sudo)
        (( index++ ))
        while (( index <= $#words )); do
          token=${(Q)words[$index]}
          if [[ $token == -- ]]; then
            (( index++ ))
            break
          fi
          [[ $token == -* ]] || break
          case $token in
            -C|-D|-g|-h|-p|-r|-t|-u)
              (( index += 2 ))
              ;;
            *)
              (( index++ ))
              ;;
          esac
        done
        continue
        ;;
    esac

    REPLY=${token:t}
    REPLY=${REPLY%.exe}
    REPLY=${REPLY:l}
    [[ $REPLY == python[0-9.]# ]] && REPLY=python
    return 0
  done

  REPLY=
  return 1
}

__ghostty_set_shell_tab_title() {
  __ghostty_set_tab_title "❯ ${PWD:t}"
}

__ghostty_preexec_tab_title() {
  emulate -L zsh

  # The third hook argument contains the fully expanded command when zsh
  # provides it; keep the typed command as a portable fallback.
  local command_line=${3:-$1}
  __ghostty_command_name "$command_line" || return 0

  local icon=${__ghostty_app_icons[$REPLY]-}
  [[ -n $icon ]] || return 0
  __ghostty_set_tab_title "$icon ${PWD:t}"
}

__ghostty_agent_animation() {
  emulate -L zsh

  local agent_kind=$1
  local label=$2
  local state_file=$3
  local tty_device=$4
  local state=idle
  local previous_state=
  local idle_marker attention_marker
  local -a frames
  local frame_index=1
  integer title_fd

  case $agent_kind in
    claude)
      idle_marker='✴️'
      attention_marker='✹︎'
      frames=(✢︎ ✶︎ ✻︎ ✽︎ ✻︎ ✶︎)
      ;;
    codex)
      idle_marker='🔻'
      attention_marker='⬣︎'
      frames=(⬩︎ ⬦︎ ◈︎ ⬥︎ ◈︎ ⬦︎)
      ;;
  esac

  exec {title_fd}> "$tty_device" || return 0

  while true; do
    IFS= read -r state < "$state_file" 2>/dev/null || state=idle

    case $state in
      working)
        printf '\e]2;%s %s\e\\\e]9;4;3\e\\' \
          "$frames[$frame_index]" "$label" >&$title_fd
        (( frame_index = frame_index % $#frames + 1 ))
        zselect -t 12 >/dev/null 2>&1
        ;;
      attention)
        if [[ $previous_state != attention ]]; then
          printf '\e]2;%s %s\e\\\e]9;4;2;100\e\\' \
            "$attention_marker" "$label" >&$title_fd
        fi
        zselect -t 20 >/dev/null 2>&1
        ;;
      done)
        if [[ $previous_state != done ]]; then
          printf '\e]2;%s %s\e\\\e]9;4;0\e\\' \
            "$idle_marker" "$label" >&$title_fd
        fi
        zselect -t 20 >/dev/null 2>&1
        ;;
      *)
        state=idle
        if [[ $previous_state != idle ]]; then
          printf '\e]2;%s %s\e\\\e]9;4;0\e\\' \
            "$idle_marker" "$label" >&$title_fd
        fi
        zselect -t 20 >/dev/null 2>&1
        ;;
    esac

    previous_state=$state
  done
}

__ghostty_run_agent() {
  emulate -L zsh

  local executable=$1
  shift
  local -a agent_args
  agent_args=("$@")

  if [[ $TERM_PROGRAM != ghostty || -z $TTY ]]; then
    command "$executable" "$@"
    return $?
  fi

  local state_file
  state_file=$(mktemp "${TMPDIR:-/tmp}/ghostty-agent-state.XXXXXXXX") || return 1
  printf '%s\n' idle >| "$state_file"

  local GHOSTTY_AGENT_STATE=$state_file
  export GHOSTTY_AGENT_STATE

  local agent_kind=$executable
  local title
  local CLAUDE_CODE_DISABLE_TERMINAL_TITLE
  case $agent_kind in
    claude)
      # Claude Code otherwise writes its own animated OSC 2 title, racing ours.
      CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
      export CLAUDE_CODE_DISABLE_TERMINAL_TITLE
      title="${PWD:t}"
      ;;
    codex)
      title="${PWD:t}"
      # Keep Codex's normal title behavior globally; suppress it only for this
      # Ghostty-owned invocation so there is exactly one OSC 2 writer.
      agent_args=(-c 'tui.terminal_title=[]' "${agent_args[@]}")
      ;;
  esac

  # Disown immediately so interactive zsh never prints job IDs or termination
  # notices for this private helper process.
  __ghostty_agent_animation "$agent_kind" "$title" "$state_file" "$TTY" &!
  local animation_pid=$!

  command "$executable" "${agent_args[@]}"
  local exit_status=$?

  kill "$animation_pid" 2>/dev/null
  wait "$animation_pid" 2>/dev/null
  command rm -f -- "$state_file"

  __ghostty_set_shell_tab_title
  printf '\e]9;4;0\e\\'
  return $exit_status
}

claude() {
  __ghostty_run_agent claude "$@"
}

codex() {
  __ghostty_run_agent codex "$@"
}

# Re-sourcing this file is safe: replace, rather than duplicate, our hooks.
add-zsh-hook -d preexec __ghostty_preexec_tab_title 2>/dev/null
add-zsh-hook -d precmd __ghostty_set_shell_tab_title 2>/dev/null
add-zsh-hook preexec __ghostty_preexec_tab_title
add-zsh-hook precmd __ghostty_set_shell_tab_title
