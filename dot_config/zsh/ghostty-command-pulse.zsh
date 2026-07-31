# Drive command-line-flash.glsl from an explicit, fixed-duration preexec event.
# Palette entry 254 is a private per-surface channel: red/green identify the
# pulse protocol and blue carries its eased brightness. The entry is restored
# after exactly 320 ms, so instant commands and long-running commands receive
# the same animation while editor navigation remains unrelated.

if (( ! ${+__GHOSTTY_COMMAND_PULSE_MARKER} )); then
  typeset -gr __GHOSTTY_COMMAND_PULSE_MARKER='#17e7'
fi
if (( ! ${+__GHOSTTY_COMMAND_PULSE_FADE} )); then
  typeset -gra __GHOSTTY_COMMAND_PULSE_FADE=(
    ff ff ff ff ff fe fb f6 f0 e8 df d4 c9 bd b0 a3
    95 87 78 6a 5c 4f 42 36 2b 20 17 0f 09 04 01 00
  )
fi
if (( ! ${+__GHOSTTY_COMMAND_PULSE_PID} )); then
  typeset -gi __GHOSTTY_COMMAND_PULSE_PID=0
fi

zmodload zsh/zselect

__ghostty_command_pulse_write() {
  emulate -L zsh

  local sequence=$1
  if (( ${+_ghostty_fd} )); then
    print -rnu "$_ghostty_fd" -- "$sequence"
  else
    print -rn -- "$sequence"
  fi
}

__ghostty_command_pulse_reset_channel() {
  emulate -L zsh
  __ghostty_command_pulse_write $'\e]104;254\e\\'
}

__ghostty_command_pulse_stop_worker() {
  emulate -L zsh

  (( __GHOSTTY_COMMAND_PULSE_PID > 0 )) || return 0
  kill "$__GHOSTTY_COMMAND_PULSE_PID" 2>/dev/null

  # The worker is disowned to prevent interactive job notices, so zsh cannot
  # wait(1) for it. Confirm termination before a replacement starts; this keeps
  # an older envelope from writing over a newer command's pulse.
  local attempt
  for attempt in {1..10}; do
    kill -0 "$__GHOSTTY_COMMAND_PULSE_PID" 2>/dev/null || break
    zselect -t 1 >/dev/null 2>&1
  done
  __GHOSTTY_COMMAND_PULSE_PID=0
}

__ghostty_command_pulse_preexec() {
  emulate -L zsh

  # A repeated submission restarts the complete envelope without allowing an
  # older worker to truncate the newer pulse.
  __ghostty_command_pulse_stop_worker
  __ghostty_command_pulse_write \
    $'\e]4;254;'"$__GHOSTTY_COMMAND_PULSE_MARKER"$'ff\e\\'

  (
    emulate -L zsh
    local amplitude
    for amplitude in "$__GHOSTTY_COMMAND_PULSE_FADE[@]"; do
      zselect -t 1 >/dev/null 2>&1
      __ghostty_command_pulse_write \
        $'\e]4;254;'"$__GHOSTTY_COMMAND_PULSE_MARKER$amplitude"$'\e\\'
    done
    __ghostty_command_pulse_reset_channel
  ) &!
  __GHOSTTY_COMMAND_PULSE_PID=$!
}

__ghostty_command_pulse_precmd() {
  emulate -L zsh

  # Ghostty and other plugins append hooks during deferred initialization.
  # Keep the semantic event writer last without coupling it to prompt rendering.
  typeset -ga preexec_functions
  preexec_functions=(
    ${preexec_functions:#__ghostty_command_pulse_preexec}
    __ghostty_command_pulse_preexec
  )

  # The old protocol used OSC 12 cursor colors. Always return the shell cursor
  # to the active theme; the palette channel above now carries all pulse state.
  __ghostty_command_pulse_write $'\e]112\e\\'
}

# Re-sourcing is safe: stop an in-flight worker, clear its private channel, and
# replace rather than duplicate hooks.
__ghostty_command_pulse_stop_worker
__ghostty_command_pulse_reset_channel
__ghostty_command_pulse_write $'\e]112\e\\'
add-zsh-hook -d preexec __ghostty_command_pulse_preexec 2>/dev/null
add-zsh-hook -d precmd __ghostty_command_pulse_precmd 2>/dev/null
add-zsh-hook preexec __ghostty_command_pulse_preexec
add-zsh-hook precmd __ghostty_command_pulse_precmd
