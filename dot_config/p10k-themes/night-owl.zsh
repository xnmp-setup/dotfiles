# Night Owl — deep-blue night coding theme by Sarah Drasner
# Palette: bg1=#011627, red=#EF5350, green=#22DA6E, yellow=#FFEB95, aqua=#21C7A8, blue=#82AAFF, purple=#C792EA

typeset -g POWERLEVEL9K_DIR_FOREGROUND=111        # night owl blue
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=66   # muted bg3 border
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=43   # night owl cyan/aqua

typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=78    # night owl green
typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=78
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=222 # night owl yellow
typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=78

typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=203  # night owl red
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196  # bright night owl red

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=43  # night owl cyan/aqua
typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=78
typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=78
typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=203
typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=203
typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=203

typeset -g POWERLEVEL9K_CHEZMOI_SHELL_FOREGROUND=203  # night owl red

# Git formatter colors (formatter itself lives in ~/.p10k.zsh)
typeset -g MY_GIT_COLOR_META='%f'
typeset -g MY_GIT_COLOR_CLEAN='%78F'  # night owl green
typeset -g MY_GIT_COLOR_MODIFIED='%222F'  # night owl yellow
typeset -g MY_GIT_COLOR_UNTRACKED='%111F'  # night owl blue
typeset -g MY_GIT_COLOR_CONFLICTED='%196F'  # bright night owl red
