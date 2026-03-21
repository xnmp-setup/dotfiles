# Golden Hour — warm darks with amber, rust, sage accents
# Palette: bg=#1a1520, amber=#d4a458, rust=#d07068, sage=#8ab070, blue=#7088aa, mauve=#b880a0

typeset -g POWERLEVEL9K_DIR_FOREGROUND=137        # warm amber-tan
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=95   # muted mauve
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=179  # bright amber

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=107   # sage green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=107
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=215 # warm orange
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=107

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=179  # amber
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=167  # rust

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=139  # dusty mauve
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=107
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=107
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=167
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=167
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=167

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=167  # rust-red

# Override git formatter colors (hardcoded in p10k.zsh)
function my_git_formatter() {
  emulate -L zsh
  if [[ -n $P9K_CONTENT ]]; then
    typeset -g my_git_format=$P9K_CONTENT
    return
  fi
  if (( $1 )); then
    local       meta='%f'
    local      clean='%107F'   # sage green
    local   modified='%215F'   # warm orange
    local  untracked='%137F'   # amber-tan
    local conflicted='%167F'   # rust
  else
    local       meta='%244F'
    local      clean='%244F'
    local   modified='%244F'
    local  untracked='%244F'
    local conflicted='%244F'
  fi
  local res
  if [[ -n $VCS_STATUS_LOCAL_BRANCH ]]; then
    local branch=${(V)VCS_STATUS_LOCAL_BRANCH}
    (( $#branch > 32 )) && branch[13,-13]="…"
    res+="${clean}${(g::)POWERLEVEL9K_VCS_BRANCH_ICON}${branch//\%/%%}"
  fi
  if [[ -n $VCS_STATUS_TAG && -z $VCS_STATUS_LOCAL_BRANCH ]]; then
    local tag=${(V)VCS_STATUS_TAG}
    (( $#tag > 32 )) && tag[13,-13]="…"
    res+="${meta}#${clean}${tag//\%/%%}"
  fi
  [[ -z $VCS_STATUS_LOCAL_BRANCH && -z $VCS_STATUS_TAG ]] &&
    res+="${meta}@${clean}${VCS_STATUS_COMMIT[1,8]}"
  if [[ -n ${VCS_STATUS_REMOTE_BRANCH:#$VCS_STATUS_LOCAL_BRANCH} ]]; then
    res+="${meta}:${clean}${(V)VCS_STATUS_REMOTE_BRANCH//\%/%%}"
  fi
  [[ -n $VCS_STATUS_ACTION     ]] && res+=" ${conflicted}${VCS_STATUS_ACTION}"
  typeset -g my_git_format=$res
}
functions -M my_git_formatter 2>/dev/null
