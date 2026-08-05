# Everforest Dark Medium — warm, forest-inspired dark color scheme (medium contrast)
# Palette: bg0=#2d353b, red=#e67e80, green=#a7c080, yellow=#dbbc7f, aqua=#83c092, blue=#7fbbb3, purple=#d699b6

typeset -g POWERLEVEL9K_DIR_FOREGROUND=109        # everforest blue
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=238  # muted bg3 border
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=108  # everforest aqua

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=144   # everforest green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=144
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=180 # everforest yellow
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=144

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=174  # everforest red
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=203  # bright everforest red

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=108  # everforest aqua
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=144
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=144
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=174
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=174
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=174

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=174  # everforest red

# Git formatter colors (formatter itself lives in ~/.p10k.zsh)
typeset -g MY_GIT_COLOR_META='%f'
typeset -g MY_GIT_COLOR_CLEAN='%144F'  # everforest green
typeset -g MY_GIT_COLOR_MODIFIED='%180F'  # everforest yellow
typeset -g MY_GIT_COLOR_UNTRACKED='%109F'  # everforest blue
typeset -g MY_GIT_COLOR_CONFLICTED='%203F'  # bright everforest red
