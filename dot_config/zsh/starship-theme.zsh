# Theme colours and directory parts for the Starship prompt
# (~/.config/starship.toml). Sourced from .zshrc when Starship is the prompt.
#
# Palette: set-theme writes ~/.config/starship/palette.toml from the Ghostty
# theme (scripts/lib/starship-theme.sh). Starship has no include directive, so
# before each prompt this splices that palette into a copy of starship.toml in
# the cache and points STARSHIP_CONFIG at it. The copy is rebuilt only when
# either source is newer, so most prompts cost two stat calls and no fork, and
# a set-theme run anywhere recolours every open shell at its next prompt.
# Without a palette file, Starship reads starship.toml as is and uses its ANSI
# fallback palette.
#
# Directory: Starship cannot bold only the last folder name, so the path is
# split here and exported for the prompt's env_var modules.

typeset -g __starship_base_config=$HOME/.config/starship.toml
typeset -g __starship_palette=${XDG_CONFIG_HOME:-$HOME/.config}/starship/palette.toml
typeset -g __starship_config=${XDG_CACHE_HOME:-$HOME/.cache}/starship/config.toml

__starship_sync_palette() {
  if [[ ! -r $__starship_palette || ! -r $__starship_base_config ]]; then
    unset STARSHIP_CONFIG
    return
  fi
  if [[ ! $__starship_config -nt $__starship_palette || ! $__starship_config -nt $__starship_base_config ]]; then
    local tmp=$__starship_config.$$
    [[ -d ${__starship_config:h} ]] || mkdir -p -- ${__starship_config:h} || return
    {
      print -r -- "${$(<$__starship_base_config)/palette = \"ansi\"/palette = \"theme\"}"
      print
      print -r -- "$(<$__starship_palette)"
    } >| $tmp && mv -f -- $tmp $__starship_config || { rm -f -- $tmp; unset STARSHIP_CONFIG; return }
  fi
  export STARSHIP_CONFIG=$__starship_config
}

# ~/.local/share/chezmoi -> head "~/.local/share/", leaf "chezmoi". Paths
# deeper than four folders keep the last four, led by "…/".
__starship_split_pwd() {
  local p=${(%):-%~}
  # ~, /, and a named directory (hash -d) shown as ~name: one part, no head.
  if [[ $p == / || ( $p == '~'* && $p != */* ) ]]; then
    unset STARSHIP_PWD_HEAD
    export STARSHIP_PWD_LEAF=$p
  else
    local head=${p:h}
    local -a parts=(${(s:/:)head})
    if (( $#parts > 3 )); then
      head="…/${(j:/:)parts[-3,-1]}"
    fi
    [[ $head == / ]] && head=
    export STARSHIP_PWD_HEAD=$head/ STARSHIP_PWD_LEAF=${p:t}
  fi
  if [[ -w $PWD ]]; then unset STARSHIP_PWD_RO; else export STARSHIP_PWD_RO=1; fi
}

__starship_theme_precmd() {
  __starship_sync_palette
  __starship_split_pwd
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd __starship_theme_precmd
