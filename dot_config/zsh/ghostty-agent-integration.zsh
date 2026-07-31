# Ghostty has no WezTerm-style format-tab-title callback, so keep the animator
# in the originating shell and let Claude/Codex hooks update its private state
# directory. OSC 2 changes the title; OSC 9;4 adds native progress/error feedback.
__ghostty_agent_animation() {
  emulate -L zsh

  local agent_kind=$1
  local fallback_label=$2
  local state_dir=$3
  local tty_device=$4
  local state=idle
  local previous_state=
  local previous_label=
  local session_id=
  local previous_session_id=
  local session_title=
  local display_label=$fallback_label
  local metadata_file=
  local metadata_signature=
  local previous_metadata_signature=
  local resolved_title=
  local title_resolver=${AGENT_SESSION_TITLE_BIN:-$HOME/.local/bin/agent-session-title}
  local routing_marker=
  local idle_marker attention_marker
  local -a frames
  local -A metadata_stat
  local frame_index=1
  integer frame_delay_cs=33
  integer title_fd

  case $agent_kind in
    claude)
      idle_marker='✴️'
      attention_marker='✹︎'
      frames=(✢︎ ✶︎ ✻︎ ✽︎ ✻︎ ✶︎)
      metadata_file=${CLAUDE_HISTORY_FILE:-"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/history.jsonl"}
      ;;
    codex)
      idle_marker='🔻'
      attention_marker='⬣︎'
      frames=(⬩︎ ⬦︎ ◈︎ ⬥︎ ◈︎ ⬦︎)
      routing_marker=$__ghostty_page_scroll_marker
      metadata_file=${CODEX_SESSION_INDEX:-"${CODEX_HOME:-$HOME/.codex}/session_index.jsonl"}
      ;;
  esac

  exec {title_fd}> "$tty_device" || return 0

  while true; do
    if [[ -r $state_dir/status ]]; then
      IFS= read -r state < "$state_dir/status" || state=idle
    else
      state=idle
    fi
    if [[ -r $state_dir/session-id ]]; then
      IFS= read -r session_id < "$state_dir/session-id" || session_id=
    else
      session_id=
    fi

    # Rename indexes are append-only. Stat them cheaply on each frame and invoke
    # the format-specific adapter only when the session or index has changed.
    metadata_signature=
    metadata_stat=()
    if [[ -n $session_id && -x $title_resolver ]] \
      && zstat -H metadata_stat -- "$metadata_file" 2>/dev/null
    then
      metadata_signature="$metadata_stat[mtime]:$metadata_stat[size]"
      if [[ $session_id != $previous_session_id \
         || $metadata_signature != $previous_metadata_signature ]]
      then
        resolved_title=$("$title_resolver" "$agent_kind" "$session_id" 2>/dev/null)
        resolved_title=${resolved_title//$'\e'/}
        resolved_title=${resolved_title//$'\a'/}
        resolved_title=${resolved_title//$'\r'/ }
        resolved_title=${resolved_title//$'\n'/ }
        session_title=$resolved_title
        previous_session_id=$session_id
        previous_metadata_signature=$metadata_signature
      fi
    elif [[ $session_id != $previous_session_id ]]; then
      session_title=
      previous_session_id=$session_id
      previous_metadata_signature=
    fi
    display_label=${session_title:-$fallback_label}

    case $state in
      working)
        printf '\e]2;%s %s%s\e\\\e]9;4;3\e\\' \
          "$frames[$frame_index]" "$display_label" "$routing_marker" >&$title_fd
        (( frame_index = frame_index % $#frames + 1 ))
        zselect -t $frame_delay_cs >/dev/null 2>&1
        ;;
      attention)
        if [[ $previous_state != attention || $previous_label != $display_label ]]; then
          printf '\e]2;%s %s%s\e\\\e]9;4;2;100\e\\' \
            "$attention_marker" "$display_label" "$routing_marker" >&$title_fd
        fi
        zselect -t 20 >/dev/null 2>&1
        ;;
      done)
        if [[ $previous_state != done || $previous_label != $display_label ]]; then
          printf '\e]2;%s %s%s\e\\\e]9;4;0\e\\' \
            "$idle_marker" "$display_label" "$routing_marker" >&$title_fd
        fi
        zselect -t 20 >/dev/null 2>&1
        ;;
      *)
        state=idle
        if [[ $previous_state != idle || $previous_label != $display_label ]]; then
          printf '\e]2;%s %s%s\e\\\e]9;4;0\e\\' \
            "$idle_marker" "$display_label" "$routing_marker" >&$title_fd
        fi
        zselect -t 20 >/dev/null 2>&1
        ;;
    esac

    previous_state=$state
    previous_label=$display_label
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

  local state_dir
  state_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-agent-state.XXXXXXXX") || return 1
  printf '%s\n' idle >| "$state_dir/status"

  local GHOSTTY_AGENT_STATE_DIR=$state_dir
  local GHOSTTY_AGENT_STATE=
  export GHOSTTY_AGENT_STATE_DIR GHOSTTY_AGENT_STATE

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
  printf '%s\n' "$agent_kind" >| "$state_dir/agent-kind"

  # Disown immediately so interactive zsh never prints job IDs or termination
  # notices for this private helper process.
  __ghostty_agent_animation "$agent_kind" "$title" "$state_dir" "$TTY" &!
  local animation_pid=$!

  command "$executable" "${agent_args[@]}"
  local exit_status=$?

  kill "$animation_pid" 2>/dev/null
  wait "$animation_pid" 2>/dev/null
  command rm -f -- \
    "$state_dir/status" \
    "$state_dir/agent-kind" \
    "$state_dir/session-id" \
    "$state_dir/transcript-path"
  command rmdir -- "$state_dir" 2>/dev/null

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
