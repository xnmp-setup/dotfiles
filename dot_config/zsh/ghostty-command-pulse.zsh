# Flash the Ghostty window on every Enter at the prompt.
#
# ~/.local/bin/ghostty-pulse plays a fixed ~320 ms envelope on palette entry
# 254, read by command-line-flash.glsl and window-flash.glsl; see that script
# for the protocol. Claude Code and Codex trigger the same pulse from their
# UserPromptSubmit hooks, since keys typed into a TUI never reach zsh.
#
# zle-line-finish runs whenever accept-line ends the line: commands, empty
# lines and PS2 continuation lines alike, but not Ctrl-C or Ctrl-D. Because
# the envelope has its own timing, command duration and output cannot shorten
# or extend it. Without ghostty-pulse installed the hook does nothing.

typeset -g __GHOSTTY_COMMAND_PULSE_BIN=$HOME/.local/bin/ghostty-pulse

autoload -Uz add-zle-hook-widget

__ghostty_command_pulse_line_finish() {
  [[ -n $TTY && -x $__GHOSTTY_COMMAND_PULSE_BIN ]] || return 0
  "$__GHOSTTY_COMMAND_PULSE_BIN" "$TTY" </dev/null >/dev/null 2>&1 &!
}
zle -N __ghostty_command_pulse_line_finish

__ghostty_command_pulse_write() {
  if (( ${+_ghostty_fd} )); then
    print -rnu "$_ghostty_fd" -- "$1"
  else
    print -rn -- "$1"
  fi
}

__ghostty_command_pulse_precmd() {
  emulate -L zsh

  # .zshrc runs `zle -N zle-line-finish` after this file is sourced, which
  # replaces add-zle-hook-widget's dispatcher. Registering from precmd runs
  # after all of .zshrc (and after any re-source of it); add-zle-hook-widget
  # reinstalls a clobbered dispatcher, keeps the widget it found as the first
  # hook, and ignores a duplicate registration.
  add-zle-hook-widget zle-line-finish __ghostty_command_pulse_line_finish

  # The previous protocol used OSC 12 cursor colors. Always return the shell
  # cursor to the active theme in case a session still carries one.
  __ghostty_command_pulse_write $'\e]112\e\\'
}

# Re-sourcing is safe: drop the old preexec trigger and any stale channel
# value, and replace rather than duplicate hooks.
add-zsh-hook -d preexec __ghostty_command_pulse_preexec 2>/dev/null
__ghostty_command_pulse_write $'\e]104;254\e\\'
add-zsh-hook precmd __ghostty_command_pulse_precmd
