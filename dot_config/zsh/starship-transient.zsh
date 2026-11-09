# Transient prompt for Starship under zsh.
#
# Once a command line is accepted, its two-line Starship prompt is redrawn as
# a bare ❯, so scrollback holds commands and output rather than repeated
# prompt blocks. Same behaviour as p10k's POWERLEVEL9K_TRANSIENT_PROMPT=always.
# Starship supports this natively only in fish, PowerShell and cmd.
#
# Source after `eval "$(starship init zsh)"`, which sets the PROMPT this file
# saves. The ❯ keeps the colour the live prompt gave it: %? is still the
# previous command's exit status when the line is accepted.

autoload -Uz add-zle-hook-widget add-zsh-hook

typeset -g __starship_full_prompt=$PROMPT
typeset -g __starship_full_rprompt=$RPROMPT
typeset -g __starship_transient_prompt='%B%(?.%F{green}.%F{red})❯%f%b '

__starship_transient_line_finish() {
  PROMPT=$__starship_transient_prompt
  RPROMPT=
  zle .reset-prompt
}
zle -N __starship_transient_line_finish

__starship_transient_precmd() {
  PROMPT=$__starship_full_prompt
  RPROMPT=$__starship_full_rprompt
}
add-zsh-hook precmd __starship_transient_precmd

# .zshrc defines zle-line-finish with a plain `zle -N` before this file is
# sourced; add-zle-hook-widget keeps that widget as the first hook. Ctrl-C
# does not run zle-line-finish, so an interrupted line keeps its full prompt.
add-zle-hook-widget zle-line-finish __starship_transient_line_finish
