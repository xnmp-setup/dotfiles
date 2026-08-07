# Invisible identity for a Ghostty surface, stamped into its window title.
#
# Ghostty is a single-instance process: every window and every tab is a surface
# of one PID, and nothing outside the process can say which surface belongs to
# which window. Hyprland can only see a window's title. So the shell writes its
# own PID into the title as Unicode tag characters, which are default-ignorable
# — compositors keep them, renderers do not draw them — and the session
# snapshot reads it back to learn which workspace this tab was on.
#
# Same encoding as dot_config/wezterm/wezterm_window_identity.lua and the
# statusbar's lib/ghostty_status.py, so a title can carry several payloads at
# once: "codex" from the agent animator, "pid:1234" from here. Ours is appended
# LAST, and that ordering is load-bearing — hypr_status_stream.py's
# WEZTERM_WINDOW_TAG is anchored at the end of the string and strips only the
# final run, so ghostty titles must be consumed via strip_invisible_metadata
# (which removes every run) rather than title_body.
#
# Sourced only from ghostty-shell-integration.zsh, which already returns early
# off Ghostty, so this is inert on every other terminal and platform.

__ghostty_encode_tag() {
  emulate -L zsh

  local payload=$1
  local encoded=
  local -i index

  for (( index = 1; index <= ${#payload}; index++ )); do
    encoded+=${(#)$(( 0xE0000 + ##${payload[index]} ))}
  done
  REPLY="${encoded}${(#)$(( 0xE007F ))}"
}

# Computed once, at source time, so the agent animator — which runs in a forked
# subshell and writes OSC 2 straight to the tty — inherits the parent shell's
# PID rather than resolving its own.
__ghostty_encode_tag "pid:$$"
typeset -g __ghostty_pid_tag=$REPLY
unset REPLY
