[[ $TERM_PROGRAM == ghostty ]] || return 0

autoload -Uz add-zsh-hook

typeset -gA __ghostty_tab_title_by_command=(
  claude '❋︎ Claude'
  codex  '⬢︎ Codex'
)

__ghostty_set_tab_title() {
  local title=${1//$'\e'/}
  title=${title//$'\a'/}
  printf '\e]2;%s\e\\' "$title"
}

__ghostty_agent_tab_title() {
  local -a command_words
  command_words=(${(z)1})

  local command_name=${command_words[1]:t}
  local title=${__ghostty_tab_title_by_command[$command_name]-}
  [[ -n $title ]] && __ghostty_set_tab_title "$title"
}

add-zsh-hook preexec __ghostty_agent_tab_title
