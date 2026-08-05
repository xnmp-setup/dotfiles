# Nord — canonical arctic, north-bluish color scheme
# Palette: bg=#2e3440, red=#bf616a, green=#a3be8c, yellow=#ebcb8b, blue=#81a1c1, cyan=#88c0d0

typeset -g POWERLEVEL9K_DIR_FOREGROUND=109        # frost blue
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=60  # muted polar night border
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=110  # frost cyan

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=144   # soft green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=144
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=222 # warm yellow
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=144

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=131  # aurora red
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=167  # bright aurora red

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=109  # frost teal
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=144
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=144
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=131
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=131
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=131

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=131  # aurora red

# Git formatter colors (formatter itself lives in ~/.p10k.zsh)
typeset -g MY_GIT_COLOR_META='%f'
typeset -g MY_GIT_COLOR_CLEAN='%144F'  # soft green
typeset -g MY_GIT_COLOR_MODIFIED='%222F'  # warm yellow
typeset -g MY_GIT_COLOR_UNTRACKED='%109F'  # frost blue
typeset -g MY_GIT_COLOR_CONFLICTED='%167F'  # bright aurora red
