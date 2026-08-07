[[ $TERM_PROGRAM == ghostty ]] || return 0

# Ghostty injects its zsh integration before ~/.zshrc but defers feature setup
# until the first prompt. Claim OSC 2 here so its built-in title writer cannot
# race these modules, including when Ghostty has not reloaded its config.
if [[ -n ${GHOSTTY_SHELL_FEATURES:-} ]]; then
  typeset -a __ghostty_shell_features
  __ghostty_shell_features=("${(@s:,:)GHOSTTY_SHELL_FEATURES}")
  __ghostty_shell_features=("${(@)__ghostty_shell_features:#title}")
  export GHOSTTY_SHELL_FEATURES="${(j:,:)__ghostty_shell_features}"
  unset __ghostty_shell_features
fi

zmodload zsh/zselect
zmodload zsh/stat
autoload -Uz add-zsh-hook

# First: both title writers below append the identity tag it defines.
source "${${(%):-%x}:A:h}/ghostty-title-tags.zsh"
source "${${(%):-%x}:A:h}/ghostty-page-scroll.zsh"
source "${${(%):-%x}:A:h}/ghostty-tab-title.zsh"
source "${${(%):-%x}:A:h}/ghostty-command-pulse.zsh"
source "${${(%):-%x}:A:h}/ghostty-agent-integration.zsh"
