# Ghostty cannot scope keybindings to the foreground process. Hyprland can see
# the active window title, so this zero-width suffix acts as a private routing
# signal while zsh or Codex owns the terminal.
typeset -g __ghostty_page_scroll_marker=$'\u2063\u2064\u2063'

__ghostty_page_scroll_title() {
  REPLY="${1}${__ghostty_page_scroll_marker}"
}
