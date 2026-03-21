# Golden Hour Light — warm light with deep amber, forest, navy accents
# Palette: bg=#e4d8c8, fg=#302620, amber=#a06820, forest=#3a6a18, navy=#38608a, plum=#7a3860

typeset -g POWERLEVEL9K_DIR_FOREGROUND=94         # deep amber-brown
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=137  # muted tan
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=124  # red

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=28    # forest green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=28
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=166 # burnt orange
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=28

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=130  # rich amber
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=124  # deep red

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=96   # plum
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=28
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=28
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=124
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=124
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=124

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=124  # red

# Override git formatter colors (hardcoded in p10k.zsh)
function my_git_formatter() {
  emulate -L zsh
  if [[ -n $P9K_CONTENT ]]; then
    typeset -g my_git_format=$P9K_CONTENT
    return
  fi
  if (( $1 )); then
    local       meta='%f'
    local      clean='%28F'    # forest green
    local   modified='%166F'   # burnt orange
    local  untracked='%94F'    # amber-brown
    local conflicted='%124F'   # deep red
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
