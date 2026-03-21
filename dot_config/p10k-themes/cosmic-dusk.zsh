# Cosmic Dusk — deep space blues with rose, cyan, green accents
# Palette: bg=#0e1330, rose=#d4607a, green=#69db7c, yellow=#fbbf24, blue=#6a7acc, cyan=#7aadcc

typeset -g POWERLEVEL9K_DIR_FOREGROUND=105        # soft lavender-blue
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=60  # muted purple
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=141  # bright lavender

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=114   # soft green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=114
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=220 # warm yellow
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=114

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=168  # rose
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=203  # bright rose

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=110  # cyan
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=114
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=114
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=168
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=168
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=168

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=168  # rose

# Override git formatter colors (hardcoded in p10k.zsh)
function my_git_formatter() {
  emulate -L zsh
  if [[ -n $P9K_CONTENT ]]; then
    typeset -g my_git_format=$P9K_CONTENT
    return
  fi
  if (( $1 )); then
    local       meta='%f'
    local      clean='%114F'   # soft green
    local   modified='%220F'   # warm yellow
    local  untracked='%105F'   # lavender-blue
    local conflicted='%203F'   # bright rose
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
