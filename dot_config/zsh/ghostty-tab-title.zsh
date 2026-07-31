[[ $TERM_PROGRAM == ghostty ]] || return 0

# Ghostty has no WezTerm-style format-tab-title callback, so keep the animator
# in the originating shell and let Claude/Codex hooks update its private state
# file. OSC 2 changes the title; OSC 9;4 adds native progress/error feedback.
zmodload zsh/zselect

__ghostty_set_tab_title() {
  local title=${1//$'\e'/}
  title=${title//$'\a'/}
  printf '\e]2;%s\e\\' "$title"
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
      idle_marker='❋︎'
      attention_marker='✹︎'
      frames=(✢︎ ✶︎ ✻︎ ✽︎ ✻︎ ✶︎)
      ;;
    codex)
      idle_marker='⬢︎'
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

  __ghostty_agent_animation "$agent_kind" "$title" "$state_file" "$TTY" &
  local animation_pid=$!

  command "$executable" "${agent_args[@]}"
  local exit_status=$?

  kill "$animation_pid" 2>/dev/null
  wait "$animation_pid" 2>/dev/null
  command rm -f -- "$state_file"

  __ghostty_set_tab_title "${PWD:t}"
  printf '\e]9;4;0\e\\'
  return $exit_status
}

claude() {
  __ghostty_run_agent claude "$@"
}

codex() {
  __ghostty_run_agent codex "$@"
}
