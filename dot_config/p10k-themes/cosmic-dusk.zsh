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

# Git formatter colors (formatter itself lives in ~/.p10k.zsh)
typeset -g MY_GIT_COLOR_META='%f'
typeset -g MY_GIT_COLOR_CLEAN='%114F'  # soft green
typeset -g MY_GIT_COLOR_MODIFIED='%220F'  # warm yellow
typeset -g MY_GIT_COLOR_UNTRACKED='%105F'  # lavender-blue
typeset -g MY_GIT_COLOR_CONFLICTED='%203F'  # bright rose
